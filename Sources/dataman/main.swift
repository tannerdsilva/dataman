import Foundation
import TToolkit
import Logging
import Commander
import NIO
import Crypto
import NIOSSH

let globalLogger = Logger(label:"guarddog")
extension Logger {
	static let global = globalLogger
}
Logger.global.info("dataman initialized.")

Group {
	$0.command("ssh") {
		let group = MultiThreadedEventLoopGroup(numberOfThreads:4)
		defer {
			try! group.syncShutdownGracefully()
		}
		let newHostKey = Curve25519.Signing.PrivateKey.init()
		let privateKey = NIOSSHPrivateKey(ed25519Key:.init())
		
	}
}.run()
//let zfs_snapshotPrefix = "gd_as_"
//
//func anchoredReferenceDate() -> Date {
//	let calendar = Calendar.current
//	return calendar.startOfDay(for:Date())
//}
//
//let dateAnchor = anchoredReferenceDate()
//
//class PoolWatcher:Hashable {
//	var queue:DispatchQueue
//
//	var zpool:ZFS.ZPool
//	
//	private var snapshots = [ZFS.Dataset:Set<ZFS.Dataset>]()
//	
//	var refreshTimer = TTimer()
//		
//	init(zpool:ZFS.ZPool) throws {
//		self.queue = DispatchQueue(label:"com.tannersilva.zfs-poolwatch")
//		self.zpool = zpool
//		
//		try refreshDatasetsAndSnapshots()
//		
//		var dateTrigger:Date? = nil
//		refreshTimer.anchor = dateAnchor
//		refreshTimer.duration = 600
//		refreshTimer.handler = { [weak self] refTimer in
//			guard let self = self else {
//				return
//			}
//			try? self.refreshDatasetsAndSnapshots()
//		}
//		refreshTimer.activate()
//	}
//	
//	func refreshDatasetsAndSnapshots() throws {
//		try queue.sync {
//			let thisPoolsDatasets = try zpool.listDatasets(depth:nil, types:[ZFS.DatasetType.filesystem, ZFS.DatasetType.volume])
//			var snapshotBuild = [ZFS.Dataset:Set<ZFS.Dataset>]()  
//			thisPoolsDatasets.explode(using: { (_, thisDS) -> (key:ZFS.Dataset, value:Set<ZFS.Dataset>) in
//				let thisDSSnapshots = try thisDS.listDatasets(depth:1, types:[ZFS.DatasetType.snapshot])
//				return (key:thisDS, value:thisDSSnapshots)
//			}, merge: { (n, thiskv) in
//				if var hasValues = snapshotBuild[thiskv.key] {
//					hasValues.formUnion(thiskv.value)
//				} else {
//					snapshotBuild[thiskv.key] = thiskv.value
//				}
//			})
//			self.snapshots = snapshotBuild
//		}
//	}
//
//	func fullSnapCommandDatasetMapping() -> [ZFS.SnapshotCommand:[ZFS.Dataset:Set<ZFS.Dataset>]] {
//		return queue.sync {
//			var buildData = [ZFS.SnapshotCommand:Set<ZFS.Dataset>]()
//		
//			func insert(snap:ZFS.SnapshotCommand, forDataset dataset:ZFS.Dataset) {
//				if var existingDatasets = buildData[snap] {
//					existingDatasets.update(with:dataset)
//				} else {
//					buildData[snap] = Set<ZFS.Dataset>([dataset])
//				}
//			}
//			snapshots.keys.explode(using: { (n, k) -> (key:ZFS.Dataset, value:Set<ZFS.SnapshotCommand>)? in
//				if let hasSnapshotCommands = k.snapshotCommands {
//					globalLogger.info("dataset identified", metadata:["full name": "\(k.name.consolidatedString())", "has snapshots": "true"])
//					return (key:k, value:hasSnapshotCommands) 
//				}
//				globalLogger.info("dataset identified", metadata:["full name": "\(k.name.consolidatedString())", "has snapshots": "false"])
//				return nil
//			}, merge: { (n, kv) -> Void in
//				for (_, curSnap) in kv.value.enumerated() {
//					insert(snap:curSnap, forDataset:kv.key)
//				}
//			})
//			
//			return buildData.explode(using: { (n, kv) -> (key:ZFS.SnapshotCommand, value:[ZFS.Dataset:Set<ZFS.Dataset>]) in
//				var datasetSnapshots = [ZFS.Dataset:Set<ZFS.Dataset>]()
//				for (_, curDataset) in kv.value.enumerated() {
//					if let hasSnapshots = self.snapshots[curDataset] {
//						datasetSnapshots[curDataset] = hasSnapshots
//					}
//				}
//				return (key:kv.key, value:datasetSnapshots)
//			})
//		}
//	}
//	
//	public func hash(into hasher:inout Hasher) {
//		hasher.combine(zpool)
//	}
//	
//	public static func == (lhs:PoolWatcher, rhs:PoolWatcher) -> Bool {
//		return lhs.zpool == rhs.zpool
//	}
//}
//
//
//extension Collection where Element == ZFS.Dataset {
//	/*
//		This function is used to help determine if a collection of snapshots are due for a new snapshot event with a snapshot command given as input
//		This function will return nil if there is no existing snapshots to derive this data from
//	*/
//	func nextSnapshotDate(with command:ZFS.SnapshotCommand) -> Date? {
//		var latestDate:Date? = nil
//		for (_, curSnapshot) in enumerated() {
//			if latestDate == nil || curSnapshot.creation > latestDate! {
//				latestDate = curSnapshot.creation
//			}
//		}
//		guard let gotLatestDate = latestDate else {
//			return nil
//		}
//		let now = Date()
//		let latestSnapshotAbsolute = gotLatestDate.timeIntervalSince1970
//		let nextSnapEvent = Date(timeIntervalSince1970:latestSnapshotAbsolute + command.secondsInterval)
//		return nextSnapEvent
//	}
//}
///*
//	This object works with the PoolWatcher objects to schedule the next snapshot.
//	This object has no regard for snapshot events that might overlap...this is simply concerned with 
//*/
//class ZFSSnapper {
//	let priority:Priority
//	let queue:DispatchQueue
//
//	var snapshotPrefix = zfs_snapshotPrefix
//
//	var poolwatchers:Set<PoolWatcher>
//
//	var snapshotCommands:[ZFS.SnapshotCommand:Set<ZFS.Dataset>]
//
//	var snapshotTimers = [TTimer]()
//	
//	let dateFormatter = DateFormatter()
//
//	init() throws {
//		self.priority = Priority.`default`
//		self.queue = DispatchQueue(label:"com.tannersilva.instance.zfs-snapper", qos:priority.asDispatchQoS())
//		let zpools = try ZFS.ZPool.all()
//		let watchers = zpools.explode(using: { (n, thisZpool) -> (key:ZFS.ZPool, value:PoolWatcher) in
//			return (key:thisZpool, value:try PoolWatcher(zpool:thisZpool)) 
//		})
//		dateFormatter.dateFormat = "yyyy-MM-dd_HH:mm:ss"
//		poolwatchers = Set(watchers.values)
//		snapshotCommands = [ZFS.SnapshotCommand:Set<ZFS.Dataset>]()
//		try fullReschedule()
//	}
//	
//	func executeSnapshots(command:ZFS.SnapshotCommand, datasets:Set<ZFS.Dataset>) throws {
//		let nowString = snapshotString()
//		for (_, newDataset) in datasets.enumerated() {
//			globalLogger.info("snapshot created", metadata:["dataset": "\(newDataset.name.consolidatedString())", "snapshot": "\(nowString)"])
//		}
//	}
//	
//	func snapshotString() -> String {
//		let nowDate = Date()
//		let nowString = queue.sync {
//			return dateFormatter.string(from:nowDate)
//		}
//		return snapshotPrefix + nowString
//	}
//
//	func fullReschedule() throws {
//		queue.sync {
//			//invalidate all existing timers
//			for (_, curTimer) in snapshotTimers.enumerated() {
//				curTimer.cancel()
//			}
//
//			//remove all timers
//			snapshotTimers.removeAll()
//
//			//explode the pools
//			poolwatchers.explode(using: { (n, curwatcher) -> [TTimer] in
//				let datasetMapping = curwatcher.fullSnapCommandDatasetMapping()
//				var buildTimers = [TTimer]()
//				//schedule a timer for each frequency of this pool
//				datasetMapping.explode(using: { (_, curPoolData) -> TTimer in
//					let snapCommand = curPoolData.key
//					let setOfDatasets = Set(curPoolData.value.keys)
//					let nextSnapshotDate = setOfDatasets.nextSnapshotDate(with:snapCommand)
//					let newTimer = TTimer()
//					newTimer.anchor = dateAnchor
//					newTimer.duration = snapCommand.secondsInterval
//					newTimer.handler = { [weak self] _ in
//						guard let self = self else {
//							return
//						}
//						try? self.executeSnapshots(command:snapCommand, datasets:setOfDatasets)
//					}
//					newTimer.activate()
//					return newTimer
//				}, merge: { (_, timerToAdd) in
//					buildTimers.append(timerToAdd)
//				})
//				return buildTimers
//			}, merge: { (_, timers) in
//				for (_, curTimer) in timers.enumerated() {
//					self.snapshotTimers.append(curTimer)
//				}
//			})
//		}		
//	}
//}
//
//func loadPoolWatchers() throws -> [ZFS.ZPool:PoolWatcher] {
//	let zpools = try ZFS.ZPool.all()
//	let watchers = zpools.explode(using: { (n, thisZpool) -> (key:ZFS.ZPool, value:PoolWatcher) in
//		return (key:thisZpool, value:try PoolWatcher(zpool:thisZpool))
//	})
//	return watchers
//}
//
//let runSemaphore = DispatchSemaphore(value:0)
//
//let snapper = try ZFSSnapper()
//
//Signals.trap(signal:.int) { signal in
//	try? snapper.fullReschedule()
//	runSemaphore.signal()
//}
//
//let allDatasets = try ZFS.Dataset.all()
//for curDS in allDatasets {
//	
//}
//
//runSemaphore.wait()

