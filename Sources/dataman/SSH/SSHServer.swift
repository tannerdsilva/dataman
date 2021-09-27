//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import Crypto
import Logging

final class SSHConnectionHandler:ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    
    
    enum Status:UInt8 {
    	case dropped = 0
    	case established = 1
    	case initialized = 2
    }
    let internalSync = DispatchQueue(label:"com.dataman.ssh-server-instance")
    
    
    var _status:Status = .dropped
    var status:Status {
    	set {
    		_status = newValue
    		Logger.global.info("status changed", metadata:["newStatus": "\(newValue)"])
    	}
    	get {
    		return _status
    	}
    }
    
    var subsystemInitDeadline:Scheduled<Void>? = nil
    
	func handlerAdded(context:ChannelHandlerContext) {
		Logger.global.info("handler added")
		defer {
			context.fireChannelActive()
		}
		self.internalSync.sync {
			self.status = .established
			context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value:true).whenFailure { error in
				context.fireErrorCaught(error)
			}
		}
	}
	
	func channelActive(context:ChannelHandlerContext) {
		defer {
			context.fireChannelActive()
		}
		Logger.global.info("channel became active")
		let welcomeMessage = "welcome to dataman".data(using:.utf8)!
		var outBuffer = ByteBuffer()
		welcomeMessage.withUnsafeBytes { someBuff in
			outBuffer.writeBytes(someBuff)
		}
		context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type:.channel, data:.byteBuffer(outBuffer)))).whenSuccess { _ in
			Logger.global.info("welcome message written")
		}
	}
	
	func channelInactive(context:ChannelHandlerContext) {
		Logger.global.info("channel inactive")
		defer {
			context.fireChannelInactive()
		}
		self.internalSync.sync {
			context.fireChannelInactive()
			self.status = .dropped
		}
	}
	
	func userInboundEventTriggered(context:ChannelHandlerContext, event:Any) {
		self.internalSync.sync {
			Logger.global.info("Event invoked", metadata:["event": "\(event)"])
			switch event {
				case let evnt as SSHChannelRequestEvent.SubsystemRequest:
					guard evnt.wantReply == true else {
						context.close(promise:nil)
						return
					}
					if self.status == .established {
						self.status = .initialized
					}
					context.channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { result in
						Logger.global.info("failure invoke result", metadata:["result": "\(result)"])
					}
				default:
					if subsystemInitDeadline != nil {
						self.subsystemInitDeadline!.cancel()
					}
					self.subsystemInitDeadline = nil
					context.close(promise:nil)
			}
		}
	}
	
	func channelRead(context:ChannelHandlerContext, data inputData:NIOAny) {
		Logger.global.info("server read data")
		let data = self.unwrapInboundIn(inputData)
        guard case .byteBuffer(let bytes) = data.data else {
            fatalError("Unexpected read type")
        }
        let inboundData = bytes.withUnsafeReadableBytes { someBuff -> Data in
        	let asData = Data(bytes:someBuff.baseAddress!, count:someBuff.count)
        	return asData
        }
        var outbuffer = ByteBuffer()
        inboundData.withUnsafeBytes { byteBuff in
        	outbuffer.writeBytes(byteBuff)
        }
       	context.writeAndFlush(self.wrapOutboundOut(SSHChannelData(type:.channel, data:.byteBuffer(outbuffer))), promise:nil)
       	context.fireChannelRead(self.wrapInboundOut(bytes))
	}
	
	deinit {
		Logger.global.info("session deinitialized")
	}
}

enum SSHServerError: Error {
    case invalidCommand
    case invalidDataType
    case invalidChannelType
    case alreadyListening
    case notListening
}

class ErrorHandler:ChannelInboundHandler {
	typealias InboundIn = Any
	
	func errorCaught(context:ChannelHandlerContext, error:Error) {
		Logger.global.error("Error in pipeline: \(error)")
		context.close(promise:nil)
	}
}

func sshChildChannelInitializer(_ channel:Channel, _ channelType:SSHChannelType) -> EventLoopFuture<Void> {
	switch channelType {
		case .session:
			return channel.pipeline.addHandler(SSHConnectionHandler())
		default:
			return channel.eventLoop.makeFailedFuture(SSHServerError.invalidChannelType)
	}
}

class SSHServer {
	class AuthenticationDelegate:NIOSSHServerUserAuthenticationDelegate {
		var supportedAuthenticationMethods:NIOSSHAvailableUserAuthenticationMethods {
			return [.publicKey, .password]
		}
		
		func requestReceived(request:NIOSSHUserAuthenticationRequest, responsePromise:EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
			Logger.global.info("attempting to authenticate", metadata:["type": "\(request.request)"])
			guard request.username == "dataman" else {
				responsePromise.succeed(.failure)
				return
			}
			switch request.request {
				case let .password(passwordRequest):
					responsePromise.succeed(.success)
				case let .publicKey(publicKeyRequest):
					let pk = publicKeyRequest.publicKey
					responsePromise.succeed(.success)
				default:
					Logger.global.info("rejecting auth request because of unknown auth type")
					responsePromise.succeed(.failure)
			}
		}
	}
	
	//this is the authentication delegate that will authenticate all active connections
	private let authDelegate:AuthenticationDelegate
	
	private let database:ApplicationDatabase
	
	private let mainChannel:Channel
	
	init(_ db:ApplicationDatabase) throws {
		self.database = db
		
		let ad = AuthenticationDelegate()
		self.authDelegate = ad
		
		//create a host key if one does not exist in the database
		let newHostKey:Curve25519.Signing.PrivateKey
		if let hasPK = db.sshPrivateKey {
			newHostKey = try Curve25519.Signing.PrivateKey(rawRepresentation:hasPK)
		} else {
			let makeKey = Curve25519.Signing.PrivateKey()
			newHostKey = makeKey
			db.sshPrivateKey = makeKey.rawRepresentation
		}
		let privateKey = NIOSSHPrivateKey(ed25519Key:newHostKey)
		
		let bootstrap = NIO.ServerBootstrap(group:mainGroup).childChannelInitializer({ channel -> EventLoopFuture<Void> in
			channel.pipeline.addHandlers([NIOSSHHandler(role:.server(.init(hostKeys:[privateKey], userAuthDelegate:ad, globalRequestDelegate:nil)), allocator:channel.allocator, inboundChildChannelInitializer:sshChildChannelInitializer(_:_:)), ErrorHandler()]) 
		}).serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1).serverChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
		let mc = try bootstrap.bind(host:"0.0.0.0", port:2222).wait()
		self.mainChannel = mc
		Logger.global.info("ssh server bound")
	}
	
	func wait() throws {
		try self.mainChannel.closeFuture.wait()
	}
}