import Foundation
import RapidLMDB
import CryptoSwift

extension ZFS.SnapshotCommand:DataConvertible {
    public init?(data:Data) {
        guard let string = String(data:data, encoding:.utf8), let snapshot = try? ZFS.SnapshotCommand(string) else {
            return nil
        }
        self = snapshot
    }
    
    public func exportData() -> Data {
        var buildString = String(self.units) + " "
        switch frequency {
            case .month:
                buildString += "mo"
            case .day:
                buildString += "d"
            case .hour:
                buildString += "h"
            case .minute:
                buildString += "m"
            case .seconds:
                buildString += "s"
            default:
            break;
        }
        if keep != nil {
            buildString += ":\(keep!)"
        }
        return buildString.data(using:.utf8)!
    }
}

class ApplicationDatabase {
    let internalSync = DispatchQueue(label:"com.guarddog.application.sync", attributes:[.concurrent])
    
    enum Error:Swift.Error {
        case processAlreadyRunning
        case invalidDatasetType
    }
    enum Databases:String {
        //dataset databases
        case name_to_uuid = "_nameUUID"
        case uuid_to_name = "_uuidName"
        case metadata = "metadata"
    }
    enum Metadatas:String {
        case exclusiveDaemonPIDLock = "_daemonPIDLock"
        case databaseVersion = "_dbversion" //UInt32 value
    }
    
    let env:Environment

	let nameUUID:Database		// [name as string] -> [uuid as string]
	let uuidName:Database		// [uuid as string] -> [dataset name as string]
	
    let metadata:Database
    
    var datasets:[String:ZFSDatasetDatabase]	// [ds uuid as string] -> [in memory dataset-database class]
    let path:URL
    
    fileprivate static func makDatasetEnv(path:URL, _ uuid:String) throws -> ZFSDatasetDatabase {
        let makeEnv = try Environment(path:path.appendingPathComponent("ds_\(uuid).lmdb").path, flags:[.noSubDir], mapSize:500000000000, maxDBs:25)
        return try ZFSDatasetDatabase(environment:makeEnv)
    }
    
    init(path:URL, pidLock:Bool = true) throws {
        let makeEnv = try Environment(path:path.appendingPathComponent("application.lmdb").path, flags:[.noSubDir], mapSize:5000000000000, maxDBs:25)
        
        let (dsets, uuidName, nameU, meta) = try makeEnv.transact(readOnly:false) { someTrans -> ([String:ZFSDatasetDatabase], Database, Database, Database) in
        	let a = try makeEnv.openDatabase(named:Databases.uuid_to_name.rawValue, flags:[.create], tx:someTrans)
        	let b = try makeEnv.openDatabase(named:Databases.name_to_uuid.rawValue, flags:[.create], tx:someTrans)
        	let c = try makeEnv.openDatabase(named:Databases.metadata.rawValue, flags:[.create], tx:someTrans)
        	
        	//handle the PID lock in the metadata database
            if (pidLock == true) {
                do {
                    let lastPid = try c.get(type:pid_t.self, forKey:Metadatas.exclusiveDaemonPIDLock.rawValue, tx:someTrans)!
                    let checkPid = kill(lastPid, 0)
                    guard checkPid != 0 else {
                        throw Error.processAlreadyRunning
                    }
                    try c.set(value:getpid(), forKey:Metadatas.exclusiveDaemonPIDLock.rawValue, tx:someTrans)
                } catch LMDBError.notFound {
                	try c.set(value:getpid(), forKey:Metadatas.exclusiveDaemonPIDLock.rawValue, tx:someTrans)
                }
            }

            //database version handling
            do {
				let getVersion = try c.get(type:UInt32.self, forKey:Metadatas.databaseVersion.rawValue, tx:someTrans)
            } catch LMDBError.notFound {
            	let initialVersion:UInt32 = 0
            	try c.set(value:initialVersion, forKey:Metadatas.databaseVersion.rawValue, flags:[.noOverwrite], tx:someTrans)
            }
			
			//make dataset database classes for every dataset found in the database
			let nameUUIDCursor = try b.cursor(tx:someTrans)
			var buildEnvs = [String:ZFSDatasetDatabase]()
			for curKV in nameUUIDCursor {
				let guidString = String(data:curKV.value)!
				let newDSDB = try Self.makeDatasetEnv(path:path, guidString)
				buildEnvs[guidString] = newDSDB
			}
			
            return (buildEnvs, a, b, c)
        }
        self.env = makeEnv
        self.nameUUID = nameU
        self.uuidName = uuidName
        self.datasets = dsets
        self.path = path
    }
    
    func createNewUUID(datasetName:String) throws -> String {
    	try env.transact(readOnly:false) { someTrans in
    		let nameUUIDCursor = try self.nameUUID.cursor(tx:someTrans)
    		let uuidNameCursor = try self.uuidName.cursor(tx:someTrans)
    		var newUUID:String
    		repeat {
    			newUUID = UUID().uuidString
    		} while try uuidNameCursor.contains(key:newUUID) == true
    		try nameUUIDCursor.set(value:newUUID, forKey:datasetName, flags:[.noOverwrite])
    		try uuidNameCursor.set(value:datasetName, forKey:newUUID, flags:[.noOverwrite])
    	}
    }
    
    static func makeDatasetEnv(path:URL, _ guidString:String) throws -> ZFSDatasetDatabase {
    	let newEnv = try Environment(path:path.appendingPathComponent("\(guidString).lmdb").path, flags:[.noSubDir], mapSize:5000000000000, maxDBs:25)
    	return try ZFSDatasetDatabase(environment:newEnv)
    } 
    
    func addDatasets(_ datasets:[ZFS.Dataset]) throws {
        try self.internalSync.sync(flags:[.barrier]) {
            try env.transact(readOnly:false) { someTrans in
				let nameUUIDCursor = try self.nameUUID.cursor(tx:someTrans)
				let uuidNameCursor = try self.uuidName.cursor(tx:someTrans)
                for dataset in datasets {
					guard dataset.type != .snapshot && dataset.type != .bookmark else {
						globalLogger.error("invalid dataset type")
						throw Error.invalidDatasetType
					}
					let currentName = dataset.name.consolidatedString().exportData()
					let currentUUID = dataset.uuid.exportData()
				
					let activeDatabase:ZFSDatasetDatabase
					do {						
						let foundNameForUUID = try uuidNameCursor.get(.setKey, key:currentUUID).value
						let foundUUIDForName = try nameUUIDCursor.get(.setKey, key:currentName).value
						if currentUUID != foundUUIDForName || currentName != foundNameForUUID {
							try uuidNameCursor.set(value:currentName, forKey:currentUUID)
							try nameUUIDCursor.set(value:currentUUID, forKey:currentName)
						}
						activeDatabase = self.datasets[dataset.uuid]!
					} catch LMDBError.notFound {
						try uuidNameCursor.set(value:currentName, forKey:currentUUID)
						try nameUUIDCursor.set(value:currentUUID, forKey:currentName)
						let newDB = try Self.makeDatasetEnv(path:self.path, dataset.uuid)
						self.datasets[dataset.uuid] = newDB
						activeDatabase = newDB
					}

					if (dataset.snapshotCommands != nil) {
						try activeDatabase.refreshSnapshotCommands(dataset.snapshotCommands!)
					}
                }
            }
        }
    }
}

class ZFSDatasetDatabase {
	enum Error:Swift.Error {
		case metadata
	}
	
	enum Databases:String {
		//listing snapshot commands and their attributes
		case snapshotCommandHashToUID = "rawStringHash_UID"	// data -> string
		case snapshotCommandUIDToLabel = "UID_label"		// string -> string
		case snapshotCommandUIDToFrequency = "UID_interval"	// string -> UInt64
		case snapshotCommandUIDKeepValue = "UID_keep"		// string -> UInt64 (optional)
		
		case as_names = "autosnap_names"	// [snapshot guid as string] -> [snapshot name as string]
		case as_cmdUID = "autosnap_cmdUID" // [snapshot guid as string] -> 
		
		case metadata = "_metadata"
	}
	
	enum Metadatas:String {
		case databaseVersion = "_dbversion"
		case datasetName = "name"
	}
	
	let env:Environment
	
	//snapshot command class
	let scHashUID:Database
	let scUIDLabel:Database
	let scUIDInterval:Database
	let scUIDKeep:Database
	
	let metadata:Database
	
	init(environment inputEnv:Environment) throws {
		let transactionResult = try inputEnv.transact(readOnly:false) { someTrans -> [Database] in
			let a = try inputEnv.openDatabase(named:Databases.snapshotCommandHashToUID.rawValue, flags:[.create], tx:someTrans)
			let b = try inputEnv.openDatabase(named:Databases.snapshotCommandUIDToLabel.rawValue, flags:[.create], tx:someTrans)
			let c = try inputEnv.openDatabase(named:Databases.snapshotCommandUIDToFrequency.rawValue, flags:[.create], tx:someTrans)
			let d = try inputEnv.openDatabase(named:Databases.snapshotCommandUIDKeepValue.rawValue, flags:[.create], tx:someTrans)
			let e = try inputEnv.openDatabase(named:Databases.metadata.rawValue, flags:[.create], tx:someTrans)
			
			//handle the database version
            do {
            	let getVersion = try e.get(type:UInt32.self, forKey:Metadatas.databaseVersion.rawValue, tx:someTrans)
            } catch LMDBError.notFound {
            	let initialVersion:UInt32 = 0
            	try e.set(value:initialVersion, forKey:Metadatas.databaseVersion.rawValue, flags:[.noOverwrite], tx:someTrans)
            }

			return [a, b, c, d, e]
		}
		self.env = transactionResult[0]
		self.scHashUID = transactionResult[1]
		self.scUIDLabel = transactionResult[2]
		self.scUIDInterval = transactionResult[3]
		self.scUIDKeep = transactionResult[4]
		self.metadata = transactionResult[5]
	}
	
	//snapshot class
	func refreshSnapshotCommands(_ foundCommands:Set<ZFS.SnapshotCommand>) {
		try env.transact(readOnly:false) { someTrans in
			let hashIDCursor = try self.scHashID.cursor(tx:someTrans)
			let existingUIDCursor = try self.scUIDInterval.cursor(tx:someTrans)
						
			var processedHashes = Set<Data>()
			for curCommand in foundCommands {
				let curCommandHash = String(describing:curCommand).data(using:.utf8)!.md5()
				processedHashes.update(with:curCommandHash)
				if (try hashIDCursor.contains(key:curCommandHash) == false) {
					//insert the snapshot command into the database
					var newUUID:String
					repeat {
						newUUID = UUID().uuidString
					} while (try existingUIDCursor.contains(key:newUUID) == false)
					
					try hashIDCursor.set(value:newUUID, forKey:curCommandHash)
					try self.scUIDLabel.set(value:curCommand.label, forKey:newUUID, flags:[.noOverwrite], tx:someTrans)
					try self.scUIDInterval.set(value:curCommand.frequency.secondsInterval(units:curCommand.units), forKey:newUUID, flags:[.noOverwrite], tx:someTrans)
					if curCommand.keep != nil {
						try self.scUIDKeep.set(value:curCommand.keep!, forKey:newUUID, flags:[.noOverwrite], tx:someTrans)
					}
				}
			}
			
			for curEntry in hashIDCursor {
				if processedHashes.contains(curEntry.key) == false {
					let curUUID = curEntry.value
					
					try hashIDCursor.deleteCurrent()
					try self.scUIDLabel.delete(key:curUUID)
					try self.scUIDInterval.delete(key:curUUID)
					
					do {
						try self.scUUIDKeep.delete(key:curUUID)
					} catch LMDBError.notFound {}
				}
			}
		}
	}
}
