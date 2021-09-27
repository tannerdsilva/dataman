import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import Crypto
import Logging

class ClientHandler:ChannelDuplexHandler {
	typealias InboundIn = SSHChannelData
	typealias InboundOut = ByteBuffer
	typealias OutboundIn = ByteBuffer
	typealias OutboundOut = SSHChannelData
	
		
	func handlerAdded(context:ChannelHandlerContext) {
		Logger.global.info("handler added")
	}
	
	func channelRegistered(context:ChannelHandlerContext) {
		Logger.global.info("channel registered")
	}
	
	func channelActive(context:ChannelHandlerContext) {
		Logger.global.info("client channel became active")
	}
	
	func userInboundEventTriggered(context:ChannelHandlerContext, event:Any) {
		Logger.global.info("inbound client event triggered", metadata:["type": "\(event)"])
	}
	
	func handlerRemoved(context:ChannelHandlerContext) {
		Logger.global.info("handler removed")
	}
	
	func channelRead(context:ChannelHandlerContext, data:NIOAny) {
		Logger.global.info("handler channel read data")
	}
	
	func write(context:ChannelHandlerContext, data:NIOAny, promise:EventLoopPromise<Void>?) {
		Logger.global.info("handler wrote data")
		let data = self.unwrapOutboundIn(data)
		print("data: \(data)")
		context.write(self.wrapOutboundOut(SSHChannelData(type:.channel, data:.byteBuffer(data))), promise:promise)
	}
	
	deinit {
		Logger.global.info("client session deinitalized")
	}
}

func sshClientChildChannelInitializer(_ channel:Channel, _ channelType:SSHChannelType) -> EventLoopFuture<Void> {
	print("client thing is being created")
	switch channelType {
		case .session:
			return channel.pipeline.addHandlers([ClientHandler()])
		default:
			return channel.eventLoop.makeFailedFuture(SSHServerError.invalidChannelType)
	}
}

class SSHClient {
	enum Error:Swift.Error {
		case publicKeyAuthenticationNotSupported
		case publicKeyRejected
		case invalidChannelType
	}
	class ClientCredentialsHandler:NIOSSHClientUserAuthenticationDelegate {
		private let username:String
		private let password:String?
		private let pk:NIOSSHPrivateKey
		init(username:String, password:String?, pk:NIOSSHPrivateKey) {
			self.username = username
			self.password = password
			self.pk = pk
		}
		
		func nextAuthenticationType(availableMethods:NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise:EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
			guard availableMethods.contains(.publicKey) else {
				Logger.global.error("public key authentication not offered")
				nextChallengePromise.fail(SSHClient.Error.publicKeyAuthenticationNotSupported)
				return
			}
			if password == nil {
				nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username:username, serviceName:"dataman", offer:.privateKey(.init(privateKey:pk))))
			} else {
				nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username:username, serviceName:"dataman", offer:.password(.init(password:self.password!))))
			}
		}
	}
	class HostKeyDelegate:NIOSSHClientServerAuthenticationDelegate {
		func validateHostKey(hostKey:NIOSSHPublicKey, validationCompletePromise:EventLoopPromise<Void>) {
			validationCompletePromise.succeed(())
		}
	}
	enum Status:UInt8 {
		case dropped = 0
		case established = 1
		case initialized = 2
	}
	
	let internalSync = DispatchQueue(label:"com.dataman.ssh-client-instance")
	
	
	private let database:ApplicationDatabase
	private let hostKeyValidator:HostKeyDelegate
	private let clientCreds:ClientCredentialsHandler
	private let mainChannel:Channel
	
	init(_ db:ApplicationDatabase) throws {
		self.database = db
		
		let newHostKey:Curve25519.Signing.PrivateKey
		if let hasPK = db.sshPrivateKey {
			newHostKey = try Curve25519.Signing.PrivateKey(rawRepresentation:hasPK)
		} else {
			let makeKey = Curve25519.Signing.PrivateKey()
			newHostKey = makeKey
			db.sshPrivateKey = makeKey.rawRepresentation
		}
		let privateKey = NIOSSHPrivateKey(ed25519Key:newHostKey)
		
		let clientCred = ClientCredentialsHandler(username:"dataman", password:nil, pk:privateKey)
		self.clientCreds = clientCred
		
		let hkv = HostKeyDelegate()
		self.hostKeyValidator = hkv
		
		let bootstrap = NIO.ClientBootstrap(group:mainGroup).channelInitializer({ channel -> EventLoopFuture<Void> in
			channel.pipeline.addHandlers([NIOSSHHandler(role:.client(.init(userAuthDelegate:clientCred, serverAuthDelegate:hkv)), allocator: channel.allocator, inboundChildChannelInitializer:nil), ErrorHandler()])
		}).channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value:1).channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value:1)
		
		let mc = try bootstrap.connect(host:"localhost", port:2222).wait()

		let sessionChannel = try mc.pipeline.handler(type:NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
			let promise = mc.eventLoop.makePromise(of:Channel.self)
			sshHandler.createChannel(promise) { childChannel, channelType in
				guard channelType == .session else {
					Logger.global.error("invalid channel type")
					return mc.eventLoop.makeFailedFuture(SSHClient.Error.invalidChannelType)
				}
				return childChannel.pipeline.addHandlers([ClientHandler()])
			}
			return promise.futureResult
		}
		sessionChannel.whenComplete { someResult in
			switch someResult {
				case .failure(let someFail):
				print("FAIL")
				case .success(let result):
				break;
			}
			Logger.global.info("client channel created", metadata:["result": "\(someResult)"])
		}
		let result = try! sessionChannel.wait()
		Logger.global.info("result captured", metadata:["type": "\(type(of:result))"])
		self.mainChannel = result
		let subsRequest = SSHChannelRequestEvent.SubsystemRequest(subsystem:"dataman", wantReply:true)
		result.triggerUserOutboundEvent(subsRequest).whenComplete { someThing in
			Logger.global.info("event emitted", metadata:["result": "\(someThing)"])
		}
	}
	
	func wait() throws {
		try self.mainChannel.closeFuture.wait()
	}
}