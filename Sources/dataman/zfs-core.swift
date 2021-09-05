import Foundation
import SwiftSlash
import Regex
import TToolkit

extension String {
    fileprivate func parsePercentage() -> Double? {
        guard let doubleConverted = Double(self) else {
            return nil
        }
        return doubleConverted / 100
    }
    
    fileprivate func parseMultiplier() -> Double? {
        guard let doubleConverted = Double(self) else {
            return nil
        }
        return doubleConverted
    }
    
    fileprivate func parseSize() -> BInt? {
        return BInt(self)
    }
}

extension Collection where Element == ZFS.DatasetType {
    /*
    This function will convert a collection of dataset types into a string that represents these types as a command filter for ZFS
    */
    fileprivate func buildTypeFilterFlag() -> String {
        var flagString = "-t "
        for (n, curType) in enumerated() {
            if (n != 0) {
                flagString.append(",")
            }
            flagString.append(curType.descriptionString)
        }
        return flagString
    }
}

public class ZFS {
    /*
    SnapshotFrequency is used to specify a duration of time which a dataset is supposed to be snapshotted
    */
    public enum SnapshotFrequency:UInt8, CustomStringConvertible {
        case month = 1
        case day = 2
        case hour = 3
        case minute = 4
        case seconds = 5
        
        /*
        This will convert a given SnapshotFrequency variable to an explicit duration value in seconds
        */
        public func secondsInterval(units:Double) -> Double {
            switch self {
                case .month:
                return units * 2629800
                case .day:
                return units * 86400
                case .hour:
                return units * 3600
                case .minute:
                return units * 60
                case .seconds:
                return units
            }
        }
        
        /*
        =======================================================================
        This function parses a human-written shapshot frequency command.
        This is an example of a snapshot frequency command:
        =======================================================================
        24h        -    Every 24 hours
        0.5h    -    Every half hour
        30m        -    Every half hour
        0.75s    -    Every 75 milliseconds
        =======================================================================
        There are two elements to a snapshot frequency command:
            -    frequency: what is the base unit that we are using to represent a given duration in time?
            -    value: what is the value of this base unit? (example of a base unit: *24* is the value in *24 hours*)
        =======================================================================
        */
        fileprivate static func parse(_ humanCommand:String) -> (value:Double, freq:SnapshotFrequency)? {
            var valueString = ""
            var typeString = ""
            for (_, curChar) in humanCommand.enumerated() {
                if curChar.isNumber == true || curChar == "." {
                    valueString.append(curChar)
                } else if curChar.isLetter == true {
                    typeString.append(curChar)
                } else {
                    return nil
                }
            }
            if let parsedValue = Double(valueString), let snapFreq = SnapshotFrequency(typeString) {
                return (value:parsedValue, freq:snapFreq)
            } else {
                return nil
            }
        }
        
        /*
        ========================================================================
        Note: Presumably this initializer would get called by another function that is able to separate the value from the frequency description
        ========================================================================
        This initializer takes a string that describes (in as few characters as possible) the frequency needed for the variable
        ========================================================================
        */
        public init?<T>(_ descriptionString:T) where T:StringProtocol {
            switch descriptionString.lowercased() {
                case "mo":
                    self = .month
                case "d":
                    self = .day
                case "h":
                    self = .hour
                case "m", "mi":
                    self = .minute
                case "s":
                    self = .seconds
                default:
                    return nil
            }
        }
        
        public var description:String {
        	get {
        		switch self {
        			case .month:
        				return "mo"
        			case .day:
        				return "d"
        			case .hour:
        				return "h"
        			case .minute:
        				return "mi"
        			case .seconds:
        				return "s"
        		}
        	}
        }
    }
    
    /*
    ===============================================================================
    A snapshot command is made of a frequency and the units for that frequency.
    The keep value is the maximum number of snapshots that are to be retained
    ===============================================================================
    Example: A SnapshotCommand that triggers a snapshot every 2.5 seconds
    -------------------------------------------------------------------------------
        - frequency = .seconds
        - units = 2.5
        - keep    = 45
    -------------------------------------------------------------------------------
    Written as a human: "2.5s:45"
    ===============================================================================
    This snapshot "2.5s:45" command must be assigned a label given a markdown-style link annotation syntax
    =========================
    [LABEL_HERE](2.5s:45)
    =========================
    Multiple snapshot commands can be assigned by separating commands by a semicolon.
    --------------------------------
    [LABEL_HERE](2.5s:45);[WEEKLY](1w:45)
    */
    public struct SnapshotCommand:Hashable, CustomStringConvertible {
        enum ParseError:Error {
            case labelNotFound
            case commandNotFound
            case invalidSnapshotCommand
        }
        let label:String
        let frequency:SnapshotFrequency
        let units:Double
        let keep:UInt?
        
        public var secondsInterval:Double {
            get {
                return frequency.secondsInterval(units:units)
            }
        }
        
        public static func parse(_ commands:String) -> Set<SnapshotCommand> {
            let subcommands = commands.split(separator:";")
            var buildResult = Set<SnapshotCommand>()
            for curCommand in subcommands {
                do {
                	let didConvertToCommand = try SnapshotCommand(String(curCommand))
                    _ = buildResult.update(with:didConvertToCommand)
                } catch _ { 
                	globalLogger.error("failed to parse string for snapshot command", metadata:["string": "\(commands)"])
                }
            }
            
            return buildResult
        }
        
        public init(_ singleCommand:String) throws {
            guard let labelParse = "(?<=\\[).*(?=\\])".r?.findFirst(in:singleCommand)?.matched else {
                throw ParseError.labelNotFound
            }
            label = labelParse
            guard let commandSec = "(?<=\\().*(?=\\))".r?.findFirst(in:singleCommand) else {
                throw ParseError.commandNotFound
            }
            let commandBreakdown = commandSec.matched.split(separator:":")
            switch commandBreakdown.count {
                case 1:
                    let firstString = String(commandBreakdown[0])
                    guard let frequencyCommand = SnapshotFrequency.parse(firstString) else {
                        throw ParseError.commandNotFound
                    }
                    frequency = frequencyCommand.freq
                    units = frequencyCommand.value
                    keep = nil
                case 2:
                    let firstString = String(commandBreakdown[0])
                    let secondString = String(commandBreakdown[1])
                    guard    let parsedKeep = UInt(secondString),
                            let parsedFrequencyCommand = SnapshotFrequency.parse(firstString) else {
                        throw ParseError.commandNotFound
                    }
                    frequency = parsedFrequencyCommand.freq
                    keep = parsedKeep
                    units = parsedFrequencyCommand.value
                    
                default:
                throw ParseError.invalidSnapshotCommand
            }
        }
        
        public func hash(into hasher:inout Hasher) {
            hasher.combine(label)
            hasher.combine(frequency)
            hasher.combine(units)
        }
        
        public var description:String {
        	get {
        		var base = "[" + self.label + "](" + String(self.units) + String(describing:self.frequency)
        		if (self.keep == nil) {
        			return base + ")"
        		} else { 
        			return base + ":" + String(self.keep!) + ")"
        		}
        	}
        }
    }
    
    /*
    ==============================================================
    In ZFS, a dataset can have four types.
    ==============================================================
        1. Filesystem: traditional filesystem structure with files and directories. Mounts to a mountpoint
        2. Volume: block storage device that typically can be found in /dev/zvol/
        3. Snapshot: If you dont know what zfs snapshots are, then I dont even know how you found this library in the first place
        4. Bookmarks: Markers that are assigned to snapshots. Helpful for tracking states (or 'heads') of snapshots
    ==============================================================
    */
    public enum DatasetType:UInt8 {
        case filesystem = 0
        case volume = 1
        case snapshot = 2
        case bookmark = 3
        
        init?(_ input:String) {
            switch input.lowercased() {
                case "filesystem":
                self = .filesystem
                
                case "volume":
                self = .volume
                
                case "snapshot":
                self = .snapshot
                
                case "bookmark":
                self = .bookmark
                
                default:
                return nil
            }
        }
        
        var descriptionString:String {
            get {
                switch self {
                case .snapshot:
                    return "snapshot"
                case .bookmark:
                    return "bookmark"
                case .volume:
                    return "volume"
                case .filesystem:
                    return "filesystem"
                }
            }
        }
    }
    
    /*
    ===========================================================
    The health enum is used to describe the state of a zpool
    ===========================================================
    */
    public enum Health:UInt8 {
        case degraded = 0
        case faulted = 1
        case offline = 2
        case online = 3
        case removed = 4
        case unavailable = 5
        
        init?(description:String) {
            switch description.uppercased() {
            case "DEGRADED":
                self = .degraded
            case "FAULTED":
                self = .faulted
            case "OFFLINE":
                self = .offline
            case "ONLINE":
                self = .online
            case "REMOVED":
                self = .removed
            case "UNAVAIL":
                self = .unavailable
            default:
                return nil
            }
        }
    }
    
    /*
    ===========================================================================================================
    ZFS datasets have a few elements to them that make them worthy of defining as a distinct data structure
    ===========================================================================================================
    ZFS dataset name will initialize given the dataset name as a string. It will automatically parse the string for the relevant parts of information
    ===========================================================================================================
    */
    public struct DatasetName:Hashable {
        public var poolName:String
        public var namePath:[String]
        
        public var snapName:String? = nil
        
        public var bookmarkName:String? = nil
        
        init?(_ inputName:String) {
            var baseName:String = inputName
            //try to identify the snapshot name if it exists
            if inputName.contains("@") == true {
                let parseSnapshotName = baseName.components(separatedBy:"@")
                guard parseSnapshotName.count == 2 else {
                    globalLogger.error("ZFS Parse Error")
                    return nil
                }
                baseName = String(parseSnapshotName[0])
                snapName = String(parseSnapshotName[1])
            }
            
            //try to identify the bookmark name if it exists
            if inputName.contains("#") == true {
                let parseBookmarkName = baseName.components(separatedBy:"#")
                guard parseBookmarkName.count == 2 else {
                    globalLogger.error("ZFS Bookmark Parse Error")
                    return nil
                }
                baseName = String(parseBookmarkName[0])
                bookmarkName = String(parseBookmarkName[1])
            }
            
            let pathComps = baseName.components(separatedBy:"/")
            guard pathComps.count > 0 else {
                globalLogger.error("ZFS Path Parse Error")
                return nil
            }
            namePath = pathComps
            poolName = pathComps.first!
        }
        
        public func consolidatedString() -> String {
            var baseString = namePath.joined(separator:"/")
            if let hasSnapName = snapName {
                baseString.append("@")
                baseString.append(hasSnapName)
            }
            if let hasBookmarkName = bookmarkName {
                baseString.append("#")
                baseString.append(hasBookmarkName)
            }
            return baseString
        }
        
        public static func == (lhs:DatasetName, rhs:DatasetName) -> Bool {
            let nameCompare = (lhs.namePath == rhs.namePath)
            let snapCompare = (lhs.snapName == rhs.snapName)
            let bookmarkCompare = (lhs.bookmarkName == rhs.bookmarkName)
            return (nameCompare && snapCompare && bookmarkCompare)
        }
        
        public func hash(into hasher:inout Hasher) {
            hasher.combine(namePath)
            if let hasBookmark = bookmarkName {
                hasher.combine(hasBookmark)
            }
            if let hasSnapshot = snapName {
                hasher.combine(hasSnapshot)
            }
        }
    }
        
    public struct Dataset:Hashable {
        fileprivate static let listCommand = "zfs list -t all -p -H -o guid,type,name,creation,reservation,refer,used,available,quota,refquota,volsize,com.dataman:auto-snapshot,com.dataman:uuid"
        
        public var type:DatasetType
        
        public var uuid:String
        public var guid:String
        public var name:DatasetName
        
        public let creation:Date
        
        public let reserved:BInt
        
        public let refer:BInt
        public let used:BInt
        public let free:BInt
        
        public let quota:BInt
        public let refQuota:BInt
        
        public let volumeSize:BInt?    // should be nil where type != .volume
        
        public let snapshotCommands:Set<SnapshotCommand>?
        
        
        static func tagAll(against database:ApplicationDatabase) throws {
        	enum DatasetTaggingError:Error {
        		case unableToAssignUUID
        	}
        	
        	let allDatasets = try Self.all()
        	for dataset in allDatasets {
        		if dataset.uuid == "-" {
        			let dsn = dataset.name.consolidatedString()
        			let newUUIDToAssign = try database.createNewUUID(datasetName:dsn)
        			guard try Command(bash:"zfs set com.dataman:uuid=\(newUUIDToAssign) \(dsn)").runSync().succeeded == true else {
        				throw DatasetTaggingError.unableToAssignUUID
        			}
        		}
        	}
        }
        
        static func all() throws -> Set<Dataset> {
        	enum DatasetListingError:Error {
        		case unableToList
        	}
        	let runResult = try Command(bash:Self.listCommand).runSync()
        	guard runResult.succeeded == true else {
        		throw DatasetListingError.unableToList
        	}
        	var buildDatabases = Set<Dataset>()
        	for curLine in runResult.stdout {
        		if let buildDS = Dataset(curLine) {
        			_ = buildDatabases.update(with:buildDS)
        		}
        	}
        	return buildDatabases
        }
        /*
        meant to initialize with data from the following command
        zfs list -p -H -o guid,type,name,creation,reservation,refer,used,available,quota,refquota,volsize,com.guarddog:auto-snapshot
        */
        fileprivate init?(_ lineData:Data) {
            guard let asString = String(data:lineData, encoding:.utf8) else {
                globalLogger.error("ZFS String Parse Error")
                return nil
            }
            let dsColumns = asString.split(omittingEmptySubsequences:false, whereSeparator: { $0.isWhitespace })
            guard dsColumns.count == 12 else {
                globalLogger.error("ZFS Column Parse Error", metadata:["columCount": "\(dsColumns)"])
                return nil
            }
            
            guid = String(dsColumns[0])
            
            let typeString = String(dsColumns[1])
            guard let parsedType = DatasetType(typeString) else {
                globalLogger.error("ZFS Type Parse Error")
                return nil
            }
            type = parsedType
            
            var dsNameString = String(dsColumns[2])
            guard let dsName = DatasetName(dsNameString) else {
                globalLogger.error("ZFS Dataset Name")
                return nil
            }
            name = dsName
            
            let creationString = String(dsColumns[3])
            guard let creationDouble = Double(creationString) else {
                globalLogger.error("ZFS Creation Date Parse Error")
                return nil
            }
            creation = Date(timeIntervalSince1970:creationDouble)

            let reservString = String(dsColumns[4])     // might not be specified (0 when no value is given)
            let referString = String(dsColumns[5])        // guaranteed
            let usedString = String(dsColumns[6])        // guaranteed
            let availString = String(dsColumns[7])        // guaranteed
            let quotaString = String(dsColumns[8])        // might not be specified (0 when no value is given)
            let refQuotaString = String(dsColumns[9])    // might not be specified (0 when no value is given)

            guard    let parsedReserve = BInt(reservString),
                    let parsedRefer = BInt(referString),
                    let parsedUsed = BInt(usedString),
                    let parsedAvail = BInt(availString),
                    let parsedQuota = BInt(quotaString),
                    let parsedRefQuota = BInt(refQuotaString) else {
                return nil
            }
            reserved = parsedReserve
            refer = parsedRefer
            used = parsedUsed
            free = parsedAvail
            quota = parsedQuota
            refQuota = parsedRefQuota
            
            let volSizeString = String(dsColumns[10])    // might not be specified (- when no value is specified)
            if volSizeString == "-" || volSizeString == "" {
                volumeSize = nil
            } else {
                guard let parsedVolSize = BInt(volSizeString) else {
                    globalLogger.error("ZFS Volume Size Parse Error")
                    return nil
                }
                volumeSize = parsedVolSize
            }
            
            let sscString = String(dsColumns[11]) // might not be specified ('-' when no value is given)
            if sscString == "-" || sscString == "" {
                snapshotCommands = nil
            } else {
                let parsedSnapshots = SnapshotCommand.parse(sscString)
                guard parsedSnapshots.count != 0 else {
                    globalLogger.error("ZFS Volume Size Parse Error")
                    return nil
                }
                snapshotCommands = parsedSnapshots
            }
            
            uuid = String(dsColumns[12])
        }
        
        public func listDatasets(types:[DatasetType]) throws -> Set<Dataset> {
            return try listDatasets(depth:nil, types:types)
        }
        
        public func listDatasets(depth:UInt?, types:[DatasetType]) throws -> Set<Dataset> {
            var bashCommand = Self.listCommand + " " + types.buildTypeFilterFlag()
            if let hasDepth = depth {
                bashCommand += " -d " + String(hasDepth) + " " + name.consolidatedString()
            } else {
                bashCommand += " -r " + name.consolidatedString()
            }
            let runCommand = Command(bash:bashCommand)
            let datasetList = try runCommand.runSync()
            let datasets = Set(datasetList.stdout.compactMap({ Dataset($0) }))
            return datasets
        }
        
        public func takeSnapshot(name snapname:String, recursive:Bool) throws {
            var nameModify = name
            nameModify.snapName = snapname
            let fullName = nameModify.consolidatedString()
            var shellCommand = "zfs snap "
            if recursive {
                shellCommand = shellCommand + "-r "
            }
            shellCommand.append(fullName)
            
            let result = try Command(bash:shellCommand).runSync()
        }
        
        public func hash(into hasher:inout Hasher) {
            hasher.combine(guid)
        }
        
        public static func == (lhs:Dataset, rhs:Dataset) -> Bool {
            return lhs.guid == rhs.guid
        }
    }
    
    public struct ZPool:Hashable {
        fileprivate static let listCommand = "zpool list -o name,size,alloc,free,expandsz,frag,cap,dedup,health,altroot,guid -pH"
        
        public let guid:String
        
        public let name:String
        
        public let volume:BInt
        public let allocated:BInt
        public let free:BInt
        
        public let frag:Double
        public let cap:Double
        
        public let dedup:Double
        
        public let health:Health
        
        public let altroot:URL?
        
        //runs a shell command to list all available ZFS pools, returns a set of ZPool objects
        public static func all() throws -> Set<ZPool> {
            let runResult = try Command(bash:Self.listCommand).runSync()
            if runResult.succeeded == false {
                return Set<ZPool>()
            } else {
                return Set(runResult.stdout.compactMap { ZPool($0) })
            }
        }

        fileprivate init?(_ lineData:Data) {
            guard let asString = String(data:lineData, encoding:.utf8) else {
                globalLogger.error("ZPool String Parse Error")
                return nil
            }
            let poolElements = asString.split(whereSeparator: { $0.isWhitespace })
            guard poolElements.count == 11 else {
                globalLogger.error("ZPool Column Parse Error")
                return nil
            }
            name = String(poolElements[0])
            let sizeString = String(poolElements[1])
            let allocString = String(poolElements[2])
            let freeString = String(poolElements[3])
            //expandsz (index 4) is not stored. idgaf
            let fragString = String(poolElements[5])
            let capString = String(poolElements[6])
            let dedupString = String(poolElements[7])
            let healthString = String(poolElements[8])
            let altrootString = String(poolElements[9])
            let guidString = String(poolElements[10])
            
            //parse the primary variables
            guard    let convertedSize = BInt(sizeString),
                    let convertedAlloc = BInt(allocString),
                    let convertedFree = BInt(freeString),
                    let fragPercent = fragString.parsePercentage(),
                    let capacityPercent = capString.parsePercentage(),
                    let dedupMultiplier = dedupString.parseMultiplier(),
                    let healthObject = ZFS.Health(description:healthString) else {
                return nil
            }

            guid = guidString
            
            volume = convertedSize
            allocated = convertedAlloc
            free = convertedFree
            
            frag = fragPercent
            cap = capacityPercent
            
            dedup = dedupMultiplier
            
            health = healthObject
            
            if altrootString == "-" || altrootString.contains("/") == false {
                altroot = nil
            } else {
                altroot = URL(fileURLWithPath:altrootString)
            }
        }
        
        public func listDatasets(depth:UInt?) throws -> Set<Dataset> {
            return try listDatasets(depth:depth, types:[.filesystem, .volume])
        }
        
        public func listDatasets() throws -> Set<Dataset> {
            return try listDatasets(depth:1, types:[.filesystem, .volume])
        }
        
        public func listDatasets(depth:UInt?, types:[DatasetType]) throws -> Set<Dataset> {
            var bashCommand = Dataset.listCommand + " " + types.buildTypeFilterFlag()
            if let hasDepth = depth {
                bashCommand += " -d " + String(hasDepth) + " " + name
            } else {
                bashCommand += " -r " + name
            }
            let datasetList = try Command(bash:bashCommand).runSync()
            let datasets = Set(datasetList.stdout.compactMap({ Dataset($0) }))
            return datasets
        }
        
        public func hash(into hasher:inout Hasher) {
            hasher.combine(name)
        }
        
        public static func == (lhs:ZPool, rhs:ZPool) -> Bool {
            return lhs.name == rhs.name
        }
    }
}

/*
== zpool status flags

-g Display vdev GUIDs instead of normal device names
-L Display real paths for vdevs. resolve all symbolic links
-P display full paths of the vdevs instead of only the last component of the path
-T u|d display a time stamp (u for internal date rep, d for standardized date rep
-v display verbose data error information
-x only display status for bools that are exhibiting errors that are otherwise unavailable

sudo zfs list -p -o available,used,refer,volsize
== dataset native properties
The following properties are supported:

    PROPERTY       EDIT  INHERIT   VALUES

    available        NO       NO   <size>
    clones           NO       NO   <dataset>[,...]
    compressratio    NO       NO   <1.00x or higher if compressed>
    createtxg        NO       NO   <uint64>
    creation         NO       NO   <date>
    defer_destroy    NO       NO   yes | no
    filesystem_count  NO       NO   <count>
    guid             NO       NO   <uint64>
    logicalreferenced  NO       NO   <size>
    logicalused      NO       NO   <size>
    mounted          NO       NO   yes | no
    origin           NO       NO   <snapshot>
    receive_resume_token  NO       NO   <string token>
    refcompressratio  NO       NO   <1.00x or higher if compressed>
    referenced       NO       NO   <size>
    snapshot_count   NO       NO   <count>
    type             NO       NO   filesystem | volume | snapshot | bookmark
    used             NO       NO   <size>
    usedbychildren   NO       NO   <size>
    usedbydataset    NO       NO   <size>
    usedbyrefreservation  NO       NO   <size>
    usedbysnapshots  NO       NO   <size>
    userrefs         NO       NO   <count>
    written          NO       NO   <size>
    aclinherit      YES      YES   discard | noallow | restricted | passthrough | passthrough-x
    acltype         YES      YES   noacl | posixacl
    atime           YES      YES   on | off
    canmount        YES       NO   on | off | noauto
    casesensitivity  NO      YES   sensitive | insensitive | mixed
    checksum        YES      YES   on | off | fletcher2 | fletcher4 | sha256 | sha512 | skein | edonr
    compression     YES      YES   on | off | lzjb | gzip | gzip-[1-9] | zle | lz4
    context         YES       NO   <selinux context>
    copies          YES      YES   1 | 2 | 3
    dedup           YES      YES   on | off | verify | sha256[,verify], sha512[,verify], skein[,verify], edonr,verify
    defcontext      YES       NO   <selinux defcontext>
    devices         YES      YES   on | off
    dnodesize       YES      YES   legacy | auto | 1k | 2k | 4k | 8k | 16k
    exec            YES      YES   on | off
    filesystem_limit YES       NO   <count> | none
    fscontext       YES       NO   <selinux fscontext>
    logbias         YES      YES   latency | throughput
    mlslabel        YES      YES   <sensitivity label>
    mountpoint      YES      YES   <path> | legacy | none
    nbmand          YES      YES   on | off
    normalization    NO      YES   none | formC | formD | formKC | formKD
    overlay         YES      YES   on | off
    primarycache    YES      YES   all | none | metadata
    quota           YES       NO   <size> | none
    readonly        YES      YES   on | off
    recordsize      YES      YES   512 to 1M, power of 2
    redundant_metadata YES      YES   all | most
    refquota        YES       NO   <size> | none
    refreservation  YES       NO   <size> | none
    relatime        YES      YES   on | off
    reservation     YES       NO   <size> | none
    rootcontext     YES       NO   <selinux rootcontext>
    secondarycache  YES      YES   all | none | metadata
    setuid          YES      YES   on | off
    sharenfs        YES      YES   on | off | share(1M) options
    sharesmb        YES      YES   on | off | sharemgr(1M) options
    snapdev         YES      YES   hidden | visible
    snapdir         YES      YES   hidden | visible
    snapshot_limit  YES       NO   <count> | none
    sync            YES      YES   standard | always | disabled
    utf8only         NO      YES   on | off
    version         YES       NO   1 | 2 | 3 | 4 | 5 | current
    volblocksize     NO      YES   512 to 128k, power of 2
    volmode         YES      YES   default | full | geom | dev | none
    volsize         YES       NO   <size>
    vscan           YES      YES   on | off
    xattr           YES      YES   on | off | dir | sa
    zoned           YES      YES   on | off
    userused@...     NO       NO   <size>
    groupused@...    NO       NO   <size>
    userquota@...   YES       NO   <size> | none
    groupquota@...  YES       NO   <size> | none
    written@<snap>   NO       NO   <size>
*/
