//
//  CallManager.swift
//  AudioPal
//
//  Created by Danno on 5/22/17.
//  Copyright © 2017 Daniel Heredia. All rights reserved.
//

import UIKit

let domain = "local"
let serviceType = "_apal._tcp."
let baseServiceName = "audiopal"
let maxBufferSize = 2048

protocol PalConnectionDelegate: class {
    func callManager(_ callManager: CallManager, didDetectNearbyPal pal: NearbyPal)
    func callManager(_ callManager: CallManager, didDetectDisconnection pal: NearbyPal)
    func callManager(_ callManager: CallManager, didDetectCallError error: Error, withPal pal: NearbyPal)
    func callManager(_ callManager: CallManager, didPal pal: NearbyPal, changeStatus status: PalStatus)
    func callManager(_ callManager: CallManager, didPal pal: NearbyPal, changeUsername username: String)
    func callManager(_ callManager: CallManager, didStartCallWithPal pal: NearbyPal)
}

protocol CallManagerDelegate: class {
    func callManager(_ callManager: CallManager, didStartCall call: Call)
    func callManager(_ callManager: CallManager, didEstablishCall call: Call)
    func callManager(_ callManager: CallManager, didEndCall call: Call, error: Error?)
    func callManager(_ callManager: CallManager, didMute: Bool, call: Call)
    func callManager(_ callManager: CallManager, didActivateSpeaker: Bool, call: Call)
}

class CallManager: NSObject, NetServiceDelegate, NetServiceBrowserDelegate, StreamDelegate, ADProcessorDelegate {
    var localService: NetService!
    var serviceBrowser: NetServiceBrowser!
    var localStatus: PalStatus = .NoAvailable
    var currentCall: Call?
    var acceptedStreams: [(input: InputStream, output: OutputStream)]!
    var nearbyPals: [NearbyPal]!
    let streamQueue: DispatchQueue
    var streamThread: Thread?
    let interactionProvider: CallInteractionProvider
    weak var palDelegate: PalConnectionDelegate?
    weak var delegate: CallManagerDelegate?

    
    fileprivate lazy var localIdentifier: UUID = {
        var uuidString = UserDefaults.standard.value(forKey: StoredValues.uuid) as? String
        var uuid: UUID!
        if (uuidString == nil) {
            uuid = UUID()
            UserDefaults.standard.set(uuid.uuidString, forKey: StoredValues.uuid)
        } else {
            uuid = NSUUID.init(uuidString: uuidString!)! as UUID
        }
        
        return uuid
    }()

    override init() {
        interactionProvider = CallInteractionProvider()
        acceptedStreams = []
        nearbyPals = []
        streamQueue = DispatchQueue(label: "audiopal.callqueue", attributes: .concurrent)
        super.init()
        interactionProvider.callManager = self
    }
    
}

// MARK: - Service initialization

extension CallManager {
    
    func setupService() {
        localService = NetService(domain: domain,
                                  type: serviceType,
                                  baseName: baseServiceName,
                                  uuid: localIdentifier,
                                  port: 0)
        localService.includesPeerToPeer = true
        localService.delegate = self
        localService.publish(options: .listenForConnections)
    }
    
    func setupBrowser() {
        serviceBrowser = NetServiceBrowser()
        serviceBrowser.includesPeerToPeer = true
        serviceBrowser.delegate = self
        serviceBrowser.searchForServices(ofType: serviceType, inDomain: domain)
        
    }
    
    public func start() {
        streamQueue.async {
            self.streamThread = Thread.current
            RunLoop.current.add(Port(), forMode: RunLoopMode.defaultRunLoopMode)// Nasty hack to keep the runloop alive :S
            RunLoop.current.run()
        }
        setupService()
        
    }
    
    public func stop() {
        if let streamThread = streamThread {
            self.perform(#selector(stopRunLoop), on: streamThread, with: nil, waitUntilDone: true)
        }
        streamThread = nil
        localService.stop()
        localService.delegate = nil
        localService = nil
        
        serviceBrowser.stop()
        serviceBrowser.delegate = nil
        serviceBrowser = nil
    }
}

// MARK: - Call amangement

extension CallManager {
    
    func startCall(toPal pal: NearbyPal) -> Bool {
        if localStatus != .Available {
            return false
        }
        
        if ADProcessor.isMicrophoneAccessDenied() {
            askForMicrophoneAccess()
            return false
        }
        
        var inputStream: InputStream?
        var outputStream: OutputStream?
        let success = pal.service.getInputStream(&inputStream, outputStream: &outputStream)
        if !success {
            return false
        }
        // Open Streams
        currentCall = Call(pal: pal, inputStream: inputStream!,
                           outputStream: outputStream!,
                           asCaller: true)
        guard let call = currentCall else{
            return false
        }
        openStreams(forCall: call)
        // Update information for nearby pals
        localStatus = .Occupied
        propagateLocalTxtRecord()
        interactionProvider.startInteraction(withCall: call)
        return true
    }
    
    func prepareOutgoingCall(_ call: Call) -> Bool {
        
        if currentCall != call {
            return false
        }
        
        call.prepareForAudioProcessing()
        call.audioProcessor?.delegate = self
        reportStartedCall(call)
        return true
    }
    
    func acceptIncomingCall(_ call: Call) -> Bool{
        if localStatus != .Available {
            return false
        }
        call.answerCall()
        // Update information for nearby pals
        localStatus = .Occupied
        propagateLocalTxtRecord()
        call.prepareForAudioProcessing()
        currentCall = call
        reportEstablishedCall(call)
        return true
    }
    
    func endCall(_ call: Call) {
        call.stopAudioProcessing()
        closeStreams(forCall: call)
        localStatus = .Available
        propagateLocalTxtRecord()
        call.ended = true
        if call == currentCall {
            currentCall = nil
        }
        if !call.interactionEnded {
            interactionProvider.endInteraction(withCall: call)
        }
        self.delegate?.callManager(self, didEndCall: call, error: nil)
        print("Call ended")
    }
    
    func toggleMute() {
        guard let currentCall = currentCall else {
            return
        }
        currentCall.toggleMute()
        self.delegate?.callManager(self, didMute: currentCall.isMuted, call: currentCall)
    }
    
    func toggleSpeaker() {
        guard let currentCall = currentCall else {
            return
        }
        currentCall.toggleSpeaker()
        self.delegate?.callManager(self, didActivateSpeaker: currentCall.useSpeakers, call: currentCall)
    }
    
    func askForMicrophoneAccess() {
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: NotificationNames.micAccessRequired),
                                        object: self,
                                        userInfo: nil)
    }
}

// MARK: - Call notifications
private extension CallManager {
    func reportStartedCall(_ call: Call) {
        self.palDelegate?.callManager(self, didStartCallWithPal: call.pal)
        self.delegate?.callManager(self, didStartCall: call)
    }
    
    func reportEstablishedCall(_ call: Call) {
        call.audioProcessor?.delegate = self
        delegate?.callManager(self, didEstablishCall: call)
    }
}

// MARK: - Stream data management

extension CallManager {
    
    func checkForDataToWrite(_ call: Call) {
        if call.callStatus == .dialing {
            let success = call.sendCallerInfo(localIdentifier)
            if !success {
                endCall(call)
            }
        }
    }
    
    func readInputData(_ inputStream: InputStream) {
        
        if currentCall?.inputStream == inputStream {
            readData(fromCall: currentCall!)
        } else {
            readDataFromUnknownStream(inputStream: inputStream)
        }
    }
    
    func readData(fromCall call: Call) {
        switch call.callStatus {
        case .presented:
            let success = call.processAnswer()
            DispatchQueue.main.async {
                if success {
                    self.interactionProvider.reportOutgoingCall(call: call)
                    self.reportEstablishedCall(call)
                } else {
                    self.endCall(call)
                }
            }
        case .onCall:
            guard let data = call.readInputBuffer() else {
                return
            }
            DispatchQueue.main.async {
                call.scheduleDataToPlay(data)
            }
        default:
            break
        }
    }
    
    func readDataFromUnknownStream(inputStream: InputStream) {
        
        guard let data = Call.readInputStream(inputStream) else {
            return
        }
        guard let foundIndex = acceptedStreams.index(where: { $0.input == inputStream }) else {
            inputStream.close()
            return
        }
        let streams = acceptedStreams[foundIndex]
        acceptedStreams.remove(at: foundIndex)
        
        if currentCall != nil {
            closeStreams(inputStream: streams.input, outputStream: streams.output)
            return
        }
        guard let uuid = UUID(data: data) else {
            closeStreams(inputStream: streams.input, outputStream: streams.output)
            return
        }
        guard let pal = getPalWithUUID(uuid) else {
            closeStreams(inputStream: streams.input, outputStream: streams.output)
            return
        }
        
        for otherStrs in acceptedStreams {
            closeStreams(inputStream: otherStrs.input, outputStream: otherStrs.output)
        }
        
        acceptedStreams.removeAll()
        DispatchQueue.main.async {
            self.currentCall = Call(pal: pal, inputStream: streams.input,
                                   outputStream: streams.output,
                                   asCaller: false)
            if let call = self.currentCall {
                self.interactionProvider.reportIncomingCall(call: call)
                self.reportStartedCall(call)
            }
        }
    }
}

// MARK: - Streams management

private extension CallManager {

    func openStreams(forCall call: Call) {
        openStreams(inputStream: call.inputStream, outputStream: call.outputStream)
    }
    
    func openStreams(inputStream: InputStream, outputStream: OutputStream) {
        guard let streamThread = streamThread else {
            return
        }
        self.perform(#selector(openStream(_:)), on: streamThread, with: inputStream, waitUntilDone: false)
        self.perform(#selector(openStream(_:)), on: streamThread, with: outputStream, waitUntilDone: false)
    }
    
    func closeStreams(forCall call: Call) {
        closeStreams(inputStream: call.inputStream, outputStream: call.outputStream)
        call.pal.service.stop() // This really do something??
    }
    
    func closeStreams(inputStream: InputStream, outputStream: OutputStream) {
        guard let streamThread = streamThread else {
            return
        }
        self.perform(#selector(closeStream(_:)), on: streamThread, with: inputStream, waitUntilDone: false)
        self.perform(#selector(closeStream(_:)), on: streamThread, with: outputStream, waitUntilDone: false)
    }
}

// MARK: - Runloop stream operations

private extension CallManager {
    
    @objc func openStream(_ stream: Stream) {
        stream.delegate = self
        stream.schedule(in: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        stream.open()
    }
    
    @objc func closeStream(_ stream: Stream) {
        stream.delegate = nil
        stream.close()
        stream.remove(from: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
    }
    
    @objc func writeToCurrentCall(_ buffer: Data) {
        guard let call = currentCall else {
            return
        }
        
        let preparedBuffer = call.prepareOutputAudioBuffer(buffer)
        _ = call.writeToOutputBuffer(data: preparedBuffer)
    }
    
    @objc func stopRunLoop() {
        CFRunLoopStop(RunLoop.current as! CFRunLoop)
    }
}

// MARK - TXT record utils

extension CallManager {
    
    func createTXTRecord() -> Data {
        // Get username data
        let username = UserDefaults.standard.value(forKey: StoredValues.username) as! String
        let username_data = username.data(using: .utf8)!
        
        //Get uuid data
        let uuid_data = localIdentifier.data
        
        // Get status data
        var statusValue = localStatus.rawValue
        let status_data = withUnsafePointer(to: &statusValue) { (unsafe_status) -> Data in
            Data(bytes: unsafe_status, count: MemoryLayout.size(ofValue: unsafe_status))
        }
        
        // Make a dictionary compatible with txt records format
        let packet: [String : Data] = [ PacketKeys.username: username_data,
                                        PacketKeys.uuid: uuid_data,
                                        PacketKeys.pal_status: status_data]
        
        // Create the record
        let txt = NetService.data(fromTXTRecord: packet)
        return txt
    }
    
    func decodeTXTRecord(_ record: Data) -> (username: String, uuid: UUID, status: PalStatus)?{
        let dict = NetService.dictionary(fromTXTRecord: record)
        if dict.count == 0 {
            return nil
        }
        guard let username_data = dict[PacketKeys.username] else {
            return nil
        }
        guard let uuid_data = dict[PacketKeys.uuid] else {
            return nil
        }
        guard let status_data = dict[PacketKeys.pal_status] else {
            return nil
        }
        
        // Decode username
        let username =  String(data: username_data, encoding: String.Encoding.utf8)!
        
        // Decode uuid
        let uuid = UUID(data: uuid_data)!
        
        //Decode status
        let status_raw: Int = status_data.withUnsafeBytes { $0.pointee }
        let status = PalStatus(rawValue: status_raw)!
        
        print("Pal updated TXT record: username \(String(describing: username)) uuid \(uuid.uuidString) status \(status)")
        
        return (username, uuid, status)
        
    }
    
    func propagateLocalTxtRecord() {
        let txtData = createTXTRecord()
        localService.setTXTRecord(txtData)
    }
    
    func processTxtUpdate(forService service: NetService, withData data: Data?) {
        if data != nil {
            let tuple = decodeTXTRecord(data!)
            if tuple == nil {
                return
            }
            
            if tuple!.uuid != service.uuid ||
                tuple!.uuid == localIdentifier {
                //If the uuid doesn't coincide or
                // it's the same than the local identifier
                // the information is not reliable
                return
            }
            
            let pal = getPalWithService(service)
            if pal != nil {
                
                updatePal(pal!, withData: tuple!)
            }
        } else {
            print("Peer not fully resolved")
        }
    }
}

// MARK: - Nearby pal utils

extension CallManager {
    
    func getPalWithService(_ service: NetService) -> NearbyPal? {
        return nearbyPals.filter{ $0.service == service }.first
    }
    
    func getPalWithUUID(_ uuid: UUID) -> NearbyPal? {
        return nearbyPals.filter{ $0.uuid == uuid || $0.service.uuid == uuid }.first
    }
    
    func addPal(withService service: NetService) -> NearbyPal {
        let existingPal = getPalWithService(service)
        
        if existingPal != nil {
            return existingPal!
        } else {
            let pal = NearbyPal(service)
            nearbyPals.append(pal)
            return pal
        }
    }
    
    func removePal(_ pal: NearbyPal) {
        guard let index = nearbyPals.index(of: pal) else {
            return
        }
        //TODO: Add events like close connections if opened
        nearbyPals.remove(at: index)
        palDelegate?.callManager(self, didDetectDisconnection: pal)
    }
    
    func updatePal(_ pal: NearbyPal, withData data:(username: String, uuid: UUID, status: PalStatus)) {
        let oldStatus = pal.status
        let oldName = pal.username
        pal.username = data.username
        pal.uuid = data.uuid
        pal.status = data.status
        
        if oldStatus != pal.status {
            if pal.status == .Available && oldStatus == .NoAvailable {
                palDelegate?.callManager(self, didDetectNearbyPal: pal)
            } else if pal.status == .NoAvailable {
                // I keep the pal, but it isn't available for the client until
                // it's available again.
                palDelegate?.callManager(self, didDetectDisconnection: pal)
            } else {
                palDelegate?.callManager(self, didPal: pal, changeStatus: pal.status)
            }
        }
        
        if oldName != nil && oldName != pal.username{
            palDelegate?.callManager(self, didPal: pal, changeUsername: pal.username!)
        }
        
    }
}

// MARK: - NetServiceDelegate

extension CallManager {
    
    public func netServiceDidPublish(_ sender: NetService) {
        if sender == localService {
            localStatus = .Available
            propagateLocalTxtRecord()
            setupBrowser()
        }
    }
    
    
    public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        //TODO: Manage error
        print("Error\(errorDict)")
    }
    
    
    public func netServiceWillResolve(_ sender: NetService) {
    }
    
    
    public func netServiceDidResolveAddress(_ sender: NetService) {
        if sender == localService {
            return
        }
        processTxtUpdate(forService: sender, withData: sender.txtRecordData())
    }
    
    
    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("Service was not resolved")
    }
    
    
    public func netServiceDidStop(_ sender: NetService) {
        
    }
    
    
    public func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        if sender == localService {
            return
        }
        processTxtUpdate(forService: sender, withData: data)
    }
    
    public func netService(_ sender: NetService, didAcceptConnectionWith inputStream: InputStream, outputStream: OutputStream) {
        if currentCall == nil {
            openStreams(inputStream: inputStream, outputStream: outputStream)
            acceptedStreams.append((inputStream, outputStream))
        } else {
            // Reject call automatically, the user is busy
            inputStream.open()
            outputStream.open()
            inputStream.close()
            outputStream.close()
        }
    }
}

// MARK: NetServiceBrowserDelegate

extension CallManager {
    
    public func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        
    }
    
    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        //TODO: Manage this event (show to the user)
        
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        //TODO: Manage this event (show to the user)
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFindDomain domainString: String, moreComing: Bool) {
        
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("Service name \(service.name)")
        let validService = service != localService &&
            service.baseName != "" &&
            service.baseName == baseServiceName
        
        if !validService {
            return
        }
        print("It's a valid service \(service.name)")
        var newPal = true
        if getPalWithService(service) == nil{
            
            if let existingPal = getPalWithUUID(service.uuid!) {
                // Just the newer version of the service will remain
                if existingPal.service.version < service.version {
                    existingPal.service = service
                    newPal = false
                } else {
                    return
                }
            }
            
            service.delegate = self
            service.resolve(withTimeout: 5.0)
            let currentQueue = OperationQueue.current?.underlyingQueue
            let time = DispatchTime.now() + DispatchTimeInterval.milliseconds(300)
            currentQueue?.asyncAfter(deadline: time) {
                service.startMonitoring()
            }
            print("Another service found \(service.name)")
            
            if newPal {
                _ = addPal(withService: service)
            }
        }
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemoveDomain domainString: String, moreComing: Bool) {
        
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool){
        let pal = getPalWithService(service)
        if pal != nil {
            self.removePal(pal!)
        }
        
    }
}

// MARK: StreamDelegate

extension CallManager {
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
            case Stream.Event.openCompleted:
                print("Completed")
            case Stream.Event.hasSpaceAvailable:
                if currentCall?.outputStream == aStream {
                    checkForDataToWrite(currentCall!)
                }
            case Stream.Event.hasBytesAvailable:
                self.readInputData(aStream as! InputStream)
            case Stream.Event.errorOccurred:
                print("Error")
//                if let call = currentCall {
//                    DispatchQueue.main.async {
//                        self.endCall(call)
//                    }
//                }
            case Stream.Event.endEncountered:
                print("End encountered")
                if let call = currentCall {
                    DispatchQueue.main.async {
                        self.endCall(call)
                    }
                }
            default:
                print("Not handled stream event")
            }
        }
}

// MARK: - ADProcessorDelegate

extension CallManager {
    
    public func processor(_ processor: ADProcessor!, didReceiveRecordedBuffer buffer: Data!) {
        guard let streamThread = streamThread else {
            return
        }
        self.perform(#selector(writeToCurrentCall(_:)), on: streamThread, with: buffer, waitUntilDone: false)
    }
    
    public func processor(_ processor: ADProcessor!, didFailPlayingBuffer buffer: Data!, withError error: Error!) {
        print("Error: Problem playing buffer \(error)")
    }
}
