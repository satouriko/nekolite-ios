import Foundation
import SwiftSignalKit
import TgVoipWebrtc
import Postbox
import TelegramCore

private final class ContextQueueImpl: NSObject, OngoingCallThreadLocalContextQueueWebrtc {
    private let queue: Queue
    
    init(queue: Queue) {
        self.queue = queue
        
        super.init()
    }
    
    func dispatch(_ f: @escaping () -> Void) {
        self.queue.async {
            f()
        }
    }
    
    func dispatch(after seconds: Double, block f: @escaping () -> Void) {
        self.queue.after(seconds, f)
    }
    
    func isCurrent() -> Bool {
        return self.queue.isCurrent()
    }
}

private protocol BroadcastPartSource: AnyObject {
    func requestPart(timestampMilliseconds: Int64, durationMilliseconds: Int64, completion: @escaping (OngoingGroupCallBroadcastPart) -> Void, rejoinNeeded: @escaping () -> Void) -> Disposable
}

private final class NetworkBroadcastPartSource: BroadcastPartSource {
    private let queue: Queue
    private let account: Account
    private let callId: Int64
    private let accessHash: Int64
    private var dataSource: AudioBroadcastDataSource?

    #if DEBUG
    private let debugDumpDirectory: TempBoxDirectory?
    #endif
    
    init(queue: Queue, account: Account, callId: Int64, accessHash: Int64) {
        self.queue = queue
        self.account = account
        self.callId = callId
        self.accessHash = accessHash

        #if DEBUG
        self.debugDumpDirectory = nil
        /*let debugDumpDirectory = TempBox.shared.tempDirectory()
        self.debugDumpDirectory = debugDumpDirectory
        print("Debug streaming dump path: \(debugDumpDirectory.path)")*/
        #endif
    }
    
    func requestPart(timestampMilliseconds: Int64, durationMilliseconds: Int64, completion: @escaping (OngoingGroupCallBroadcastPart) -> Void, rejoinNeeded: @escaping () -> Void) -> Disposable {
        let timestampIdMilliseconds: Int64
        if timestampMilliseconds != 0 {
            timestampIdMilliseconds = timestampMilliseconds
        } else {
            timestampIdMilliseconds = (Int64(Date().timeIntervalSince1970 * 1000.0) / durationMilliseconds) * durationMilliseconds
        }
        
        let dataSource: Signal<AudioBroadcastDataSource?, NoError>
        if let dataSourceValue = self.dataSource {
            dataSource = .single(dataSourceValue)
        } else {
            dataSource = getAudioBroadcastDataSource(account: self.account, callId: self.callId, accessHash: self.accessHash)
        }

        let callId = self.callId
        let accessHash = self.accessHash
        
        let queue = self.queue
        let signal = dataSource
        |> deliverOn(self.queue)
        |> mapToSignal { [weak self] dataSource -> Signal<GetAudioBroadcastPartResult?, NoError> in
            if let dataSource = dataSource {
                self?.dataSource = dataSource
                return getAudioBroadcastPart(dataSource: dataSource, callId: callId, accessHash: accessHash, timestampIdMilliseconds: timestampIdMilliseconds, durationMilliseconds: durationMilliseconds)
                |> map(Optional.init)
            } else {
                return .single(nil)
                |> delay(2.0, queue: queue)
            }
        }
        |> deliverOn(self.queue)

        #if DEBUG
        let debugDumpDirectory = self.debugDumpDirectory
        #endif
            
        return signal.start(next: { result in
            guard let result = result else {
                completion(OngoingGroupCallBroadcastPart(timestampMilliseconds: timestampIdMilliseconds, responseTimestamp: Double(timestampIdMilliseconds), status: .notReady, oggData: Data()))
                return
            }
            let part: OngoingGroupCallBroadcastPart
            switch result.status {
            case let .data(dataValue):
                #if DEBUG
                if let debugDumpDirectory = debugDumpDirectory {
                    let _ = try? dataValue.write(to: URL(fileURLWithPath: debugDumpDirectory.path + "/" + "\(timestampIdMilliseconds).ogg"))
                }
                #endif

                part = OngoingGroupCallBroadcastPart(timestampMilliseconds: timestampIdMilliseconds, responseTimestamp: result.responseTimestamp, status: .success, oggData: dataValue)
            case .notReady:
                part = OngoingGroupCallBroadcastPart(timestampMilliseconds: timestampIdMilliseconds, responseTimestamp: result.responseTimestamp, status: .notReady, oggData: Data())
            case .resyncNeeded:
                part = OngoingGroupCallBroadcastPart(timestampMilliseconds: timestampIdMilliseconds, responseTimestamp: result.responseTimestamp, status: .resyncNeeded, oggData: Data())
            case .rejoinNeeded:
                rejoinNeeded()
                return
            }
            
            completion(part)
        })
    }
}

private final class OngoingGroupCallBroadcastPartTaskImpl : NSObject, OngoingGroupCallBroadcastPartTask {
    private let disposable: Disposable?
    
    init(disposable: Disposable?) {
        self.disposable = disposable
    }
    
    func cancel() {
        self.disposable?.dispose()
    }
}

public final class OngoingGroupCallContext {
    public struct AudioStreamData {
        public var account: Account
        public var callId: Int64
        public var accessHash: Int64
        
        public init(account: Account, callId: Int64, accessHash: Int64) {
            self.account = account
            self.callId = callId
            self.accessHash = accessHash
        }
    }
    
    public enum ConnectionMode {
        case none
        case rtc
        case broadcast
    }
    
    public enum VideoContentType {
        case none
        case generic
        case screencast
    }
    
    public struct NetworkState: Equatable {
        public var isConnected: Bool
        public var isTransitioningFromBroadcastToRtc: Bool
    }
    
    public enum AudioLevelKey: Hashable {
        case local
        case source(UInt32)
    }

    public struct MediaChannelDescription {
        public enum Kind {
            case audio
            case video
        }

        public var kind: Kind
        public var audioSsrc: UInt32
        public var videoDescription: String?

        public init(kind: Kind, audioSsrc: UInt32, videoDescription: String?) {
            self.kind = kind
            self.audioSsrc = audioSsrc
            self.videoDescription = videoDescription
        }
    }

    public struct VideoChannel: Equatable {
        public enum Quality {
            case thumbnail
            case medium
            case full
        }

        public var audioSsrc: UInt32
        public var videoDescription: String
        public var quality: Quality

        public init(audioSsrc: UInt32, videoDescription: String, quality: Quality) {
            self.audioSsrc = audioSsrc
            self.videoDescription = videoDescription
            self.quality = quality
        }
    }
    
    private final class Impl {
        let queue: Queue
        let context: GroupCallThreadLocalContext
        
        let sessionId = UInt32.random(in: 0 ..< UInt32(Int32.max))
        
        let joinPayload = Promise<(String, UInt32)>()
        let networkState = ValuePromise<NetworkState>(NetworkState(isConnected: false, isTransitioningFromBroadcastToRtc: false), ignoreRepeated: true)
        let isMuted = ValuePromise<Bool>(true, ignoreRepeated: true)
        let isNoiseSuppressionEnabled = ValuePromise<Bool>(true, ignoreRepeated: true)
        let audioLevels = ValuePipe<[(AudioLevelKey, Float, Bool)]>()

        private var currentRequestedVideoChannels: [VideoChannel] = []
        
        private var broadcastPartsSource: BroadcastPartSource?
        
        init(queue: Queue, inputDeviceId: String, outputDeviceId: String, video: OngoingCallVideoCapturer?, requestMediaChannelDescriptions: @escaping (Set<UInt32>, @escaping ([MediaChannelDescription]) -> Void) -> Disposable, audioStreamData: AudioStreamData?, rejoinNeeded: @escaping () -> Void, outgoingAudioBitrateKbit: Int32?, videoContentType: VideoContentType, enableNoiseSuppression: Bool) {
            self.queue = queue
            
            var networkStateUpdatedImpl: ((GroupCallNetworkState) -> Void)?
            var audioLevelsUpdatedImpl: (([NSNumber]) -> Void)?
            
            if let audioStreamData = audioStreamData {
                let broadcastPartsSource = NetworkBroadcastPartSource(queue: queue, account: audioStreamData.account, callId: audioStreamData.callId, accessHash: audioStreamData.accessHash)
                self.broadcastPartsSource = broadcastPartsSource
            }
            
            let broadcastPartsSource = self.broadcastPartsSource
            
            let _videoContentType: OngoingGroupCallVideoContentType
            switch videoContentType {
            case .generic:
                _videoContentType = .generic
            case .screencast:
                _videoContentType = .screencast
            case .none:
                _videoContentType = .none
            }

            self.context = GroupCallThreadLocalContext(
                queue: ContextQueueImpl(queue: queue),
                networkStateUpdated: { state in
                    networkStateUpdatedImpl?(state)
                },
                audioLevelsUpdated: { levels in
                    audioLevelsUpdatedImpl?(levels)
                },
                inputDeviceId: inputDeviceId,
                outputDeviceId: outputDeviceId,
                videoCapturer: video?.impl,
                requestMediaChannelDescriptions: { ssrcs, completion in
                    final class OngoingGroupCallMediaChannelDescriptionTaskImpl : NSObject, OngoingGroupCallMediaChannelDescriptionTask {
                        private let disposable: Disposable

                        init(disposable: Disposable) {
                            self.disposable = disposable
                        }

                        func cancel() {
                            self.disposable.dispose()
                        }
                    }

                    let disposable = requestMediaChannelDescriptions(Set(ssrcs.map { $0.uint32Value }), { channels in
                        completion(channels.map { channel -> OngoingGroupCallMediaChannelDescription in
                            let mappedType: OngoingGroupCallMediaChannelType
                            switch channel.kind {
                            case .audio:
                                mappedType = .audio
                            case .video:
                                mappedType = .video
                            }
                            return OngoingGroupCallMediaChannelDescription(
                                type: mappedType,
                                audioSsrc: channel.audioSsrc,
                                videoDescription: channel.videoDescription
                            )
                        })
                    })

                    return OngoingGroupCallMediaChannelDescriptionTaskImpl(disposable: disposable)
                },
                requestBroadcastPart: { timestampMilliseconds, durationMilliseconds, completion in
                    let disposable = MetaDisposable()
                    
                    queue.async {
                        disposable.set(broadcastPartsSource?.requestPart(timestampMilliseconds: timestampMilliseconds, durationMilliseconds: durationMilliseconds, completion: completion, rejoinNeeded: {
                            rejoinNeeded()
                        }))
                    }
                    
                    return OngoingGroupCallBroadcastPartTaskImpl(disposable: disposable)
                },
                outgoingAudioBitrateKbit: outgoingAudioBitrateKbit ?? 32,
                videoContentType: _videoContentType,
                enableNoiseSuppression: enableNoiseSuppression
            )
            
            let queue = self.queue
            
            networkStateUpdatedImpl = { [weak self] state in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.networkState.set(NetworkState(isConnected: state.isConnected, isTransitioningFromBroadcastToRtc: state.isTransitioningFromBroadcastToRtc))
                }
            }
            
            let audioLevels = self.audioLevels
            audioLevelsUpdatedImpl = { levels in
                var mappedLevels: [(AudioLevelKey, Float, Bool)] = []
                var i = 0
                while i < levels.count {
                    let uintValue = levels[i].uint32Value
                    let key: AudioLevelKey
                    if uintValue == 0 {
                        key = .local
                    } else {
                        key = .source(uintValue)
                    }
                    mappedLevels.append((key, levels[i + 1].floatValue, levels[i + 2].boolValue))
                    i += 3
                }
                queue.async {
                    audioLevels.putNext(mappedLevels)
                }
            }
            
            self.context.emitJoinPayload({ [weak self] payload, ssrc in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.joinPayload.set(.single((payload, ssrc)))
                }
            })
        }
        
        deinit {
        }
        
        func setJoinResponse(payload: String) {
            self.context.setJoinResponsePayload(payload)
        }
        
        func addSsrcs(ssrcs: [UInt32]) {
        }
        
        func removeSsrcs(ssrcs: [UInt32]) {
            if ssrcs.isEmpty {
                return
            }
            self.context.removeSsrcs(ssrcs.map { ssrc in
                return ssrc as NSNumber
            })
        }

        func removeIncomingVideoSource(_ ssrc: UInt32) {
            self.context.removeIncomingVideoSource(ssrc)
        }
        
        func setVolume(ssrc: UInt32, volume: Double) {
            self.context.setVolumeForSsrc(ssrc, volume: volume)
        }

        func setRequestedVideoChannels(_ channels: [VideoChannel]) {
            if self.currentRequestedVideoChannels != channels {
                self.currentRequestedVideoChannels = channels

                self.context.setRequestedVideoChannels(channels.map { channel -> OngoingGroupCallRequestedVideoChannel in
                    let mappedQuality: OngoingGroupCallRequestedVideoQuality
                    switch channel.quality {
                    case .thumbnail:
                        mappedQuality = .thumbnail
                    case .medium:
                        mappedQuality = .medium
                    case .full:
                        mappedQuality = .full
                    }
                    return OngoingGroupCallRequestedVideoChannel(
                        audioSsrc: channel.audioSsrc,
                        videoInformation: channel.videoDescription,
                        quality: mappedQuality
                    )
                })
            }
        }
        
        func stop() {
            self.context.stop()
        }
        
        func setConnectionMode(_ connectionMode: ConnectionMode, keepBroadcastConnectedIfWasEnabled: Bool) {
            let mappedConnectionMode: OngoingCallConnectionMode
            switch connectionMode {
            case .none:
                mappedConnectionMode = .none
            case .rtc:
                mappedConnectionMode = .rtc
            case .broadcast:
                mappedConnectionMode = .broadcast
            }
            self.context.setConnectionMode(mappedConnectionMode, keepBroadcastConnectedIfWasEnabled: keepBroadcastConnectedIfWasEnabled)
            
            if (mappedConnectionMode != .rtc) {
                self.joinPayload.set(.never())
                
                let queue = self.queue
                self.context.emitJoinPayload({ [weak self] payload, ssrc in
                    queue.async {
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.joinPayload.set(.single((payload, ssrc)))
                    }
                })
            }
        }
        
        func setIsMuted(_ isMuted: Bool) {
            self.isMuted.set(isMuted)
            self.context.setIsMuted(isMuted)
        }

        func setIsNoiseSuppressionEnabled(_ isNoiseSuppressionEnabled: Bool) {
            self.isNoiseSuppressionEnabled.set(isNoiseSuppressionEnabled)
            self.context.setIsNoiseSuppressionEnabled(isNoiseSuppressionEnabled)
        }
        
        func requestVideo(_ capturer: OngoingCallVideoCapturer?) {
            let queue = self.queue
            self.context.requestVideo(capturer?.impl, completion: { [weak self] payload, ssrc in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.joinPayload.set(.single((payload, ssrc)))
                }
            })
        }
        
        public func disableVideo() {
            let queue = self.queue
            self.context.disableVideo({ [weak self] payload, ssrc in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.joinPayload.set(.single((payload, ssrc)))
                }
            })
        }
        
        func switchAudioInput(_ deviceId: String) {
            self.context.switchAudioInput(deviceId)
        }
        
        func switchAudioOutput(_ deviceId: String) {
            self.context.switchAudioOutput(deviceId)
        }
        
        func makeIncomingVideoView(endpointId: String, completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
            self.context.makeIncomingVideoView(withEndpointId: endpointId, completion: { view in
                if let view = view {
                    #if os(iOS)
                    completion(OngoingCallContextPresentationCallVideoView(
                        view: view,
                        setOnFirstFrameReceived: { [weak view] f in
                            view?.setOnFirstFrameReceived(f)
                        },
                        getOrientation: { [weak view] in
                            if let view = view {
                                return OngoingCallVideoOrientation(view.orientation)
                            } else {
                                return .rotation0
                            }
                        },
                        getAspect: { [weak view] in
                            if let view = view {
                                return view.aspect
                            } else {
                                return 0.0
                            }
                        },
                        setOnOrientationUpdated: { [weak view] f in
                            view?.setOnOrientationUpdated { value, aspect in
                                f?(OngoingCallVideoOrientation(value), aspect)
                            }
                        },
                        setOnIsMirroredUpdated: { [weak view] f in
                            view?.setOnIsMirroredUpdated { value in
                                f?(value)
                            }
                        },
                        updateIsEnabled: { [weak view] value in
                            view?.updateIsEnabled(value)
                        }
                    ))
                    #else
                    completion(OngoingCallContextPresentationCallVideoView(
                        view: view,
                        setOnFirstFrameReceived: { [weak view] f in
                            view?.setOnFirstFrameReceived(f)
                        },
                        getOrientation: { [weak view] in
                            if let view = view {
                                return OngoingCallVideoOrientation(view.orientation)
                            } else {
                                return .rotation0
                            }
                        },
                        getAspect: { [weak view] in
                            if let view = view {
                                return view.aspect
                            } else {
                                return 0.0
                            }
                        },
                        setOnOrientationUpdated: { [weak view] f in
                            view?.setOnOrientationUpdated { value, aspect in
                                f?(OngoingCallVideoOrientation(value), aspect)
                            }
                        }, setVideoContentMode: { [weak view] mode in
                            view?.setVideoContentMode(mode)
                        },
                        setOnIsMirroredUpdated: { [weak view] f in
                            view?.setOnIsMirroredUpdated { value in
                                f?(value)
                            }
                        }
                    ))
                    #endif
                } else {
                    completion(nil)
                }
            })
        }
    }
    
    private let queue = Queue()
    private let impl: QueueLocalObject<Impl>
    
    public var joinPayload: Signal<(String, UInt32), NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.joinPayload.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
    
    public var networkState: Signal<NetworkState, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.networkState.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
    
    public var audioLevels: Signal<[(AudioLevelKey, Float, Bool)], NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.audioLevels.signal().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
    
    public var isMuted: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isMuted.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }

    public var isNoiseSuppressionEnabled: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isNoiseSuppressionEnabled.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
    
    public init(inputDeviceId: String = "", outputDeviceId: String = "", video: OngoingCallVideoCapturer?, requestMediaChannelDescriptions: @escaping (Set<UInt32>, @escaping ([MediaChannelDescription]) -> Void) -> Disposable, audioStreamData: AudioStreamData?, rejoinNeeded: @escaping () -> Void, outgoingAudioBitrateKbit: Int32?, videoContentType: VideoContentType, enableNoiseSuppression: Bool) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return Impl(queue: queue, inputDeviceId: inputDeviceId, outputDeviceId: outputDeviceId, video: video, requestMediaChannelDescriptions: requestMediaChannelDescriptions, audioStreamData: audioStreamData, rejoinNeeded: rejoinNeeded, outgoingAudioBitrateKbit: outgoingAudioBitrateKbit, videoContentType: videoContentType, enableNoiseSuppression: enableNoiseSuppression)
        })
    }
    
    public func setConnectionMode(_ connectionMode: ConnectionMode, keepBroadcastConnectedIfWasEnabled: Bool) {
        self.impl.with { impl in
            impl.setConnectionMode(connectionMode, keepBroadcastConnectedIfWasEnabled: keepBroadcastConnectedIfWasEnabled)
        }
    }
    
    public func setIsMuted(_ isMuted: Bool) {
        self.impl.with { impl in
            impl.setIsMuted(isMuted)
        }
    }

    public func setIsNoiseSuppressionEnabled(_ isNoiseSuppressionEnabled: Bool) {
        self.impl.with { impl in
            impl.setIsNoiseSuppressionEnabled(isNoiseSuppressionEnabled)
        }
    }
    
    public func requestVideo(_ capturer: OngoingCallVideoCapturer?) {
        self.impl.with { impl in
            impl.requestVideo(capturer)
        }
    }
    
    public func disableVideo() {
        self.impl.with { impl in
            impl.disableVideo()
        }
    }
    
    public func switchAudioInput(_ deviceId: String) {
        self.impl.with { impl in
            impl.switchAudioInput(deviceId)
        }
    }
    public func switchAudioOutput(_ deviceId: String) {
        self.impl.with { impl in
            impl.switchAudioOutput(deviceId)
        }
    }
    public func setJoinResponse(payload: String) {
        self.impl.with { impl in
            impl.setJoinResponse(payload: payload)
        }
    }
    
    public func addSsrcs(ssrcs: [UInt32]) {
        self.impl.with { impl in
            impl.addSsrcs(ssrcs: ssrcs)
        }
    }
    
    public func removeSsrcs(ssrcs: [UInt32]) {
        self.impl.with { impl in
            impl.removeSsrcs(ssrcs: ssrcs)
        }
    }

    public func removeIncomingVideoSource(_ ssrc: UInt32) {
        self.impl.with { impl in
            impl.removeIncomingVideoSource(ssrc)
        }
    }
    
    public func setVolume(ssrc: UInt32, volume: Double) {
        self.impl.with { impl in
            impl.setVolume(ssrc: ssrc, volume: volume)
        }
    }

    public func setRequestedVideoChannels(_ channels: [VideoChannel]) {
        self.impl.with { impl in
            impl.setRequestedVideoChannels(channels)
        }
    }
    
    public func stop() {
        self.impl.with { impl in
            impl.stop()
        }
    }
    
    public func makeIncomingVideoView(endpointId: String, completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
        self.impl.with { impl in
            impl.makeIncomingVideoView(endpointId: endpointId, completion: completion)
        }
    }
}
