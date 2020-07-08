import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SyncCore
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import TelegramAudio
import AccountContext
import LocalizedPeerData
import PhotoResources
import CallsEmoji

private final class IncomingVideoNode: ASDisplayNode {
    private let videoView: UIView
    private var effectView: UIVisualEffectView?
    private var isBlurred: Bool = false
    
    init(videoView: UIView) {
        self.videoView = videoView
        
        super.init()
        
        self.view.addSubview(self.videoView)
    }
    
    func updateLayout(size: CGSize) {
        self.videoView.frame = CGRect(origin: CGPoint(), size: size)
    }
    
    func updateIsBlurred(isBlurred: Bool) {
        if self.isBlurred == isBlurred {
            return
        }
        self.isBlurred = isBlurred
        
        if isBlurred {
            if self.effectView == nil {
                let effectView = UIVisualEffectView()
                self.effectView = effectView
                effectView.frame = self.videoView.frame
                self.view.addSubview(effectView)
            }
            UIView.animate(withDuration: 0.3, animations: {
                self.effectView?.effect = UIBlurEffect(style: .dark)
            })
        } else if let effectView = self.effectView {
            UIView.animate(withDuration: 0.3, animations: {
                effectView.effect = nil
            })
        }
    }
}

private final class OutgoingVideoNode: ASDisplayNode {
    private let videoView: UIView
    private let switchCameraButton: HighlightableButtonNode
    private let switchCamera: () -> Void
    
    init(videoView: UIView, switchCamera: @escaping () -> Void) {
        self.videoView = videoView
        self.switchCameraButton = HighlightableButtonNode()
        self.switchCamera = switchCamera
        
        super.init()
        
        self.view.addSubview(self.videoView)
        self.addSubnode(self.switchCameraButton)
        self.switchCameraButton.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
    }
    
    @objc private func buttonPressed() {
        self.switchCamera()
    }
    
    func updateLayout(size: CGSize, isExpanded: Bool, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(view: self.videoView, frame: CGRect(origin: CGPoint(), size: size))
        transition.updateCornerRadius(layer: self.videoView.layer, cornerRadius: isExpanded ? 0.0 : 16.0)
        self.switchCameraButton.frame = CGRect(origin: CGPoint(), size: size)
    }
}

final class LegacyCallControllerNode: ASDisplayNode, CallControllerNodeProtocol {
    private let sharedContext: SharedAccountContext
    private let account: Account
    
    private let statusBar: StatusBar
    
    private var presentationData: PresentationData
    private var peer: Peer?
    private let debugInfo: Signal<(String, String), NoError>
    private var forceReportRating = false
    private let easyDebugAccess: Bool
    private let call: PresentationCall
    
    private let containerNode: ASDisplayNode
    
    private let imageNode: TransformImageNode
    private let dimNode: ASDisplayNode
    private var incomingVideoNode: IncomingVideoNode?
    private var incomingVideoViewRequested: Bool = false
    private var outgoingVideoNode: OutgoingVideoNode?
    private var outgoingVideoViewRequested: Bool = false
    private let backButtonArrowNode: ASImageNode
    private let backButtonNode: HighlightableButtonNode
    private let statusNode: CallControllerStatusNode
    private let videoPausedNode: ImmediateTextNode
    private let buttonsNode: LegacyCallControllerButtonsNode
    private var keyPreviewNode: CallControllerKeyPreviewNode?
    
    private var debugNode: CallDebugNode?
    
    private var keyTextData: (Data, String)?
    private let keyButtonNode: HighlightableButtonNode
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
    
    var isMuted: Bool = false {
        didSet {
            self.buttonsNode.isMuted = self.isMuted
        }
    }
    
    private var shouldStayHiddenUntilConnection: Bool = false
    
    private var audioOutputState: ([AudioSessionOutput], currentOutput: AudioSessionOutput?)?
    private var callState: PresentationCallState?
    
    var toggleMute: (() -> Void)?
    var setCurrentAudioOutput: ((AudioSessionOutput) -> Void)?
    var beginAudioOuputSelection: (() -> Void)?
    var acceptCall: (() -> Void)?
    var endCall: (() -> Void)?
    var toggleVideo: (() -> Void)?
    var back: (() -> Void)?
    var presentCallRating: ((CallId) -> Void)?
    var callEnded: ((Bool) -> Void)?
    var dismissedInteractively: (() -> Void)?
    var setIsVideoPaused: ((Bool) -> Void)?
    
    init(sharedContext: SharedAccountContext, account: Account, presentationData: PresentationData, statusBar: StatusBar, debugInfo: Signal<(String, String), NoError>, shouldStayHiddenUntilConnection: Bool = false, easyDebugAccess: Bool, call: PresentationCall) {
        self.sharedContext = sharedContext
        self.account = account
        self.presentationData = presentationData
        self.statusBar = statusBar
        self.debugInfo = debugInfo
        self.shouldStayHiddenUntilConnection = shouldStayHiddenUntilConnection
        self.easyDebugAccess = easyDebugAccess
        self.call = call
        
        self.containerNode = ASDisplayNode()
        if self.shouldStayHiddenUntilConnection {
            self.containerNode.alpha = 0.0
        }
        
        self.imageNode = TransformImageNode()
        self.imageNode.contentAnimations = [.subsequentUpdates]
        self.dimNode = ASDisplayNode()
        self.dimNode.isUserInteractionEnabled = false
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        
        self.backButtonArrowNode = ASImageNode()
        self.backButtonArrowNode.displayWithoutProcessing = true
        self.backButtonArrowNode.displaysAsynchronously = false
        self.backButtonArrowNode.image = NavigationBarTheme.generateBackArrowImage(color: .white)
        self.backButtonNode = HighlightableButtonNode()
        
        self.statusNode = CallControllerStatusNode()
        
        self.videoPausedNode = ImmediateTextNode()
        self.videoPausedNode.alpha = 0.0
        
        self.buttonsNode = LegacyCallControllerButtonsNode(strings: self.presentationData.strings)
        self.keyButtonNode = HighlightableButtonNode()
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.containerNode.backgroundColor = .black
        
        self.addSubnode(self.containerNode)
        
        self.backButtonNode.setTitle(presentationData.strings.Common_Back, with: Font.regular(17.0), with: .white, for: [])
        self.backButtonNode.hitTestSlop = UIEdgeInsets(top: -8.0, left: -20.0, bottom: -8.0, right: -8.0)
        self.backButtonNode.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.backButtonNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonArrowNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonNode.alpha = 0.4
                    strongSelf.backButtonArrowNode.alpha = 0.4
                } else {
                    strongSelf.backButtonNode.alpha = 1.0
                    strongSelf.backButtonArrowNode.alpha = 1.0
                    strongSelf.backButtonNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                    strongSelf.backButtonArrowNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.containerNode.addSubnode(self.imageNode)
        self.containerNode.addSubnode(self.dimNode)
        self.containerNode.addSubnode(self.statusNode)
        self.containerNode.addSubnode(self.videoPausedNode)
        self.containerNode.addSubnode(self.buttonsNode)
        self.containerNode.addSubnode(self.keyButtonNode)
        self.containerNode.addSubnode(self.backButtonArrowNode)
        self.containerNode.addSubnode(self.backButtonNode)
        
        self.buttonsNode.mute = { [weak self] in
            self?.toggleMute?()
        }
        
        self.buttonsNode.speaker = { [weak self] in
            self?.beginAudioOuputSelection?()
        }
        
        self.buttonsNode.end = { [weak self] in
            self?.endCall?()
        }
        
        self.buttonsNode.accept = { [weak self] in
            self?.acceptCall?()
        }
        
        self.buttonsNode.toggleVideo = { [weak self] in
            self?.toggleVideo?()
        }
        
        self.buttonsNode.rotateCamera = { [weak self] in
            self?.call.switchVideoCamera()
        }
        
        self.keyButtonNode.addTarget(self, action: #selector(self.keyPressed), forControlEvents: .touchUpInside)
        
        self.backButtonNode.addTarget(self, action: #selector(self.backPressed), forControlEvents: .touchUpInside)
    }
    
    override func didLoad() {
        super.didLoad()
        
        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        self.view.addGestureRecognizer(panRecognizer)
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.view.addGestureRecognizer(tapRecognizer)
    }
    
    func updatePeer(accountPeer: Peer, peer: Peer, hasOther: Bool) {
        if !arePeersEqual(self.peer, peer) {
            self.peer = peer
            if let peerReference = PeerReference(peer), !peer.profileImageRepresentations.isEmpty {
                let representations: [ImageRepresentationWithReference] = peer.profileImageRepresentations.map({ ImageRepresentationWithReference(representation: $0, reference: .avatar(peer: peerReference, resource: $0.resource)) })
                self.imageNode.setSignal(chatAvatarGalleryPhoto(account: self.account, representations: representations, autoFetchFullSize: true))
                self.dimNode.isHidden = false
            } else {
                self.imageNode.setSignal(callDefaultBackground())
                self.dimNode.isHidden = true
            }
            
            self.statusNode.title = peer.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            if hasOther {
                self.statusNode.subtitle = self.presentationData.strings.Call_AnsweringWithAccount(accountPeer.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).0
                
                if let callState = callState {
                    self.updateCallState(callState)
                }
            }
            
            self.videoPausedNode.attributedText = NSAttributedString(string: self.presentationData.strings.Call_RemoteVideoPaused(peer.compactDisplayTitle).0, font: Font.regular(17.0), textColor: .white)
            
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
    }
    
    func updateAudioOutputs(availableOutputs: [AudioSessionOutput], currentOutput: AudioSessionOutput?) {
        if self.audioOutputState?.0 != availableOutputs || self.audioOutputState?.1 != currentOutput {
            self.audioOutputState = (availableOutputs, currentOutput)
            self.updateButtonsMode()
        }
    }
    
    func updateCallState(_ callState: PresentationCallState) {
        self.callState = callState
        
        let statusValue: CallControllerStatusValue
        var statusReception: Int32?
        
        switch callState.videoState {
        case .active:
            if !self.incomingVideoViewRequested {
                self.incomingVideoViewRequested = true
                self.call.makeIncomingVideoView(completion: { [weak self] incomingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    if let incomingVideoView = incomingVideoView {
                        strongSelf.setCurrentAudioOutput?(.speaker)
                        let incomingVideoNode = IncomingVideoNode(videoView: incomingVideoView)
                        strongSelf.incomingVideoNode = incomingVideoNode
                        strongSelf.containerNode.insertSubnode(incomingVideoNode, aboveSubnode: strongSelf.dimNode)
                        strongSelf.statusNode.isHidden = true
                        if let (layout, navigationBarHeight) = strongSelf.validLayout {
                            strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                        }
                    }
                })
            }
            if !self.outgoingVideoViewRequested {
                self.outgoingVideoViewRequested = true
                self.call.makeOutgoingVideoView(completion: { [weak self] outgoingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    if let outgoingVideoView = outgoingVideoView {
                        outgoingVideoView.backgroundColor = .black
                        outgoingVideoView.clipsToBounds = true
                        strongSelf.setCurrentAudioOutput?(.speaker)
                        let outgoingVideoNode = OutgoingVideoNode(videoView: outgoingVideoView, switchCamera: {
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.call.switchVideoCamera()
                        })
                        strongSelf.outgoingVideoNode = outgoingVideoNode
                        if let incomingVideoNode = strongSelf.incomingVideoNode {
                            strongSelf.containerNode.insertSubnode(outgoingVideoNode, aboveSubnode: incomingVideoNode)
                        } else {
                            strongSelf.containerNode.insertSubnode(outgoingVideoNode, aboveSubnode: strongSelf.dimNode)
                        }
                        if let (layout, navigationBarHeight) = strongSelf.validLayout {
                            strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                        }
                    }
                })
            }
        case .activeOutgoing:
            if !self.outgoingVideoViewRequested {
                self.outgoingVideoViewRequested = true
                self.call.makeOutgoingVideoView(completion: { [weak self] outgoingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    if let outgoingVideoView = outgoingVideoView {
                        outgoingVideoView.backgroundColor = .black
                        outgoingVideoView.clipsToBounds = true
                        outgoingVideoView.layer.cornerRadius = 16.0
                        strongSelf.setCurrentAudioOutput?(.speaker)
                        let outgoingVideoNode = OutgoingVideoNode(videoView: outgoingVideoView, switchCamera: {
                            guard let strongSelf = self else {
                                return
                            }
                            strongSelf.call.switchVideoCamera()
                        })
                        strongSelf.outgoingVideoNode = outgoingVideoNode
                        if let incomingVideoNode = strongSelf.incomingVideoNode {
                            strongSelf.containerNode.insertSubnode(outgoingVideoNode, aboveSubnode: incomingVideoNode)
                        } else {
                            strongSelf.containerNode.insertSubnode(outgoingVideoNode, aboveSubnode: strongSelf.dimNode)
                        }
                        if let (layout, navigationBarHeight) = strongSelf.validLayout {
                            strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                        }
                    }
                })
            }
        default:
            break
        }
        
        if let incomingVideoNode = self.incomingVideoNode {
            let isActive: Bool
            switch callState.remoteVideoState {
            case .inactive:
                isActive = false
            case .active:
                isActive = true
            }
            incomingVideoNode.updateIsBlurred(isBlurred: !isActive)
            if isActive != self.videoPausedNode.alpha.isZero {
                if isActive {
                    self.videoPausedNode.alpha = 0.0
                    self.videoPausedNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
                } else {
                    self.videoPausedNode.alpha = 1.0
                    self.videoPausedNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                }
            }
        }
        
        switch callState.state {
            case .waiting, .connecting:
                statusValue = .text(self.presentationData.strings.Call_StatusConnecting)
            case let .requesting(ringing):
                if ringing {
                    statusValue = .text(self.presentationData.strings.Call_StatusRinging)
                } else {
                    statusValue = .text(self.presentationData.strings.Call_StatusRequesting)
                }
            case .terminating:
                statusValue = .text(self.presentationData.strings.Call_StatusEnded)
            case let .terminated(_, reason, _):
                if let reason = reason {
                    switch reason {
                        case let .ended(type):
                            switch type {
                                case .busy:
                                    statusValue = .text(self.presentationData.strings.Call_StatusBusy)
                                case .hungUp, .missed:
                                    statusValue = .text(self.presentationData.strings.Call_StatusEnded)
                            }
                        case .error:
                            statusValue = .text(self.presentationData.strings.Call_StatusFailed)
                    }
                } else {
                    statusValue = .text(self.presentationData.strings.Call_StatusEnded)
                }
            case .ringing:
                var text = self.presentationData.strings.Call_StatusIncoming
                if !self.statusNode.subtitle.isEmpty {
                    text += "\n\(self.statusNode.subtitle)"
                }
                statusValue = .text(text)
            case .active(let timestamp, let reception, let keyVisualHash), .reconnecting(let timestamp, let reception, let keyVisualHash):
                let strings = self.presentationData.strings
                var isReconnecting = false
                if case .reconnecting = callState.state {
                    isReconnecting = true
                }
                statusValue = .timer({ value in
                    if isReconnecting {
                        return strings.Call_StatusConnecting
                    } else {
                        return strings.Call_StatusOngoing(value).0
                    }
                }, timestamp)
                if self.keyTextData?.0 != keyVisualHash {
                    let text = stringForEmojiHashOfData(keyVisualHash, 4)!
                    self.keyTextData = (keyVisualHash, text)
                    
                    self.keyButtonNode.setAttributedTitle(NSAttributedString(string: text, attributes: [NSAttributedString.Key.font: Font.regular(22.0), NSAttributedString.Key.kern: 2.5 as NSNumber]), for: [])
                    
                    let keyTextSize = self.keyButtonNode.measure(CGSize(width: 200.0, height: 200.0))
                    self.keyButtonNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                    self.keyButtonNode.frame = CGRect(origin: self.keyButtonNode.frame.origin, size: keyTextSize)
                    
                    if let (layout, navigationBarHeight) = self.validLayout {
                        self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                    }
                }
                statusReception = reception
        }
        switch callState.state {
            case .terminated, .terminating:
                if !self.statusNode.alpha.isEqual(to: 0.5) {
                    self.statusNode.alpha = 0.5
                    self.buttonsNode.alpha = 0.5
                    self.keyButtonNode.alpha = 0.5
                    self.backButtonArrowNode.alpha = 0.5
                    self.backButtonNode.alpha = 0.5
                    
                    self.statusNode.layer.animateAlpha(from: 1.0, to: 0.5, duration: 0.25)
                    self.buttonsNode.layer.animateAlpha(from: 1.0, to: 0.5, duration: 0.25)
                    self.keyButtonNode.layer.animateAlpha(from: 1.0, to: 0.5, duration: 0.25)
                }
            default:
                if !self.statusNode.alpha.isEqual(to: 1.0) {
                    self.statusNode.alpha = 1.0
                    self.buttonsNode.alpha = 1.0
                    self.keyButtonNode.alpha = 1.0
                    self.backButtonArrowNode.alpha = 1.0
                    self.backButtonNode.alpha = 1.0
                }
        }
        if self.shouldStayHiddenUntilConnection {
            switch callState.state {
                case .connecting, .active:
                    self.containerNode.alpha = 1.0
                default:
                    break
            }
        }
        self.statusNode.status = statusValue
        self.statusNode.reception = statusReception
        
        self.updateButtonsMode()
        
        if case let .terminated(id, _, reportRating) = callState.state, let callId = id {
            let presentRating = reportRating || self.forceReportRating
            if presentRating {
                self.presentCallRating?(callId)
            }
            self.callEnded?(presentRating)
        }
    }
    
    private func updateButtonsMode() {
        guard let callState = self.callState else {
            return
        }
        
        switch callState.state {
            case .ringing:
                self.buttonsNode.updateMode(.incoming)
            default:
                var mode: LegacyCallControllerButtonsSpeakerMode = .none
                if let (availableOutputs, maybeCurrentOutput) = self.audioOutputState, let currentOutput = maybeCurrentOutput {
                    switch currentOutput {
                        case .builtin:
                            mode = .builtin
                        case .speaker:
                            mode = .speaker
                        case .headphones:
                            mode = .headphones
                        case .port:
                            mode = .bluetooth
                    }
                    if availableOutputs.count <= 1 {
                        mode = .none
                    }
                }
                let mappedVideoState: LegacyCallControllerButtonsMode.VideoState
                switch callState.videoState {
                case .notAvailable:
                    mappedVideoState = .notAvailable
                case .available:
                    mappedVideoState = .available(true)
                case .active:
                    mappedVideoState = .active
                case .activeOutgoing:
                    mappedVideoState = .active
                }
                self.buttonsNode.updateMode(.active(speakerMode: mode, videoState: mappedVideoState))
        }
    }
    
    func animateIn() {
        var bounds = self.bounds
        bounds.origin = CGPoint()
        self.bounds = bounds
        self.layer.removeAnimation(forKey: "bounds")
        self.statusBar.layer.removeAnimation(forKey: "opacity")
        self.containerNode.layer.removeAnimation(forKey: "opacity")
        self.containerNode.layer.removeAnimation(forKey: "scale")
        self.statusBar.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
        if !self.shouldStayHiddenUntilConnection {
            self.containerNode.layer.animateScale(from: 1.04, to: 1.0, duration: 0.3)
            self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        }
    }
    
    func animateOut(completion: @escaping () -> Void) {
        self.statusBar.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        if !self.shouldStayHiddenUntilConnection || self.containerNode.alpha > 0.0 {
            self.containerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
            self.containerNode.layer.animateScale(from: 1.0, to: 1.04, duration: 0.3, removeOnCompletion: false, completion: { _ in
                completion()
            })
        } else {
            completion()
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)
        
        transition.updateFrame(node: self.containerNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        if let keyPreviewNode = self.keyPreviewNode {
            transition.updateFrame(node: keyPreviewNode, frame: CGRect(origin: CGPoint(), size: layout.size))
            keyPreviewNode.updateLayout(size: layout.size, transition: .immediate)
        }
        
        transition.updateFrame(node: self.imageNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let arguments = TransformImageArguments(corners: ImageCorners(), imageSize: CGSize(width: 640.0, height: 640.0).aspectFilled(layout.size), boundingSize: layout.size, intrinsicInsets: UIEdgeInsets())
        let apply = self.imageNode.asyncLayout()(arguments)
        apply()
        
        let navigationOffset: CGFloat = max(20.0, layout.safeInsets.top)
        
        let backSize = self.backButtonNode.measure(CGSize(width: 320.0, height: 100.0))
        if let image = self.backButtonArrowNode.image {
            transition.updateFrame(node: self.backButtonArrowNode, frame: CGRect(origin: CGPoint(x: 10.0, y: navigationOffset + 11.0), size: image.size))
        }
        transition.updateFrame(node: self.backButtonNode, frame: CGRect(origin: CGPoint(x: 29.0, y: navigationOffset + 11.0), size: backSize))
        
        var statusOffset: CGFloat
        if layout.metrics.widthClass == .regular && layout.metrics.heightClass == .regular {
            if layout.size.height.isEqual(to: 1366.0) {
                statusOffset = 160.0
            } else {
                statusOffset = 120.0
            }
        } else {
            if layout.size.height.isEqual(to: 736.0) {
                statusOffset = 80.0
            } else if layout.size.width.isEqual(to: 320.0) {
                statusOffset = 60.0
            } else {
                statusOffset = 64.0
            }
        }
        
        statusOffset += layout.safeInsets.top
        
        let buttonsHeight: CGFloat = 75.0
        let buttonsOffset: CGFloat
        if layout.size.width.isEqual(to: 320.0) {
            if layout.size.height.isEqual(to: 480.0) {
                buttonsOffset = 60.0
            } else {
                buttonsOffset = 73.0
            }
        } else {
            buttonsOffset = 83.0
        }
        
        let statusHeight = self.statusNode.updateLayout(constrainedWidth: layout.size.width, transition: transition)
        transition.updateFrame(node: self.statusNode, frame: CGRect(origin: CGPoint(x: 0.0, y: statusOffset), size: CGSize(width: layout.size.width, height: statusHeight)))
        
        let videoPausedSize = self.videoPausedNode.updateLayout(CGSize(width: layout.size.width - 16.0, height: 100.0))
        transition.updateFrame(node: self.videoPausedNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - videoPausedSize.width) / 2.0), y: floor((layout.size.height - videoPausedSize.height) / 2.0)), size: videoPausedSize))
        
        self.buttonsNode.updateLayout(constrainedWidth: layout.size.width, transition: transition)
        let buttonsOriginY: CGFloat = layout.size.height - (buttonsOffset - 40.0) - buttonsHeight - layout.intrinsicInsets.bottom
        transition.updateFrame(node: self.buttonsNode, frame: CGRect(origin: CGPoint(x: 0.0, y: buttonsOriginY), size: CGSize(width: layout.size.width, height: buttonsHeight)))
        
        var outgoingVideoTransition = transition
        if let incomingVideoNode = self.incomingVideoNode {
            if incomingVideoNode.frame.width.isZero, let outgoingVideoNode = self.outgoingVideoNode, !outgoingVideoNode.frame.width.isZero, !transition.isAnimated {
                outgoingVideoTransition = .animated(duration: 0.3, curve: .easeInOut)
            }
            incomingVideoNode.frame = CGRect(origin: CGPoint(), size: layout.size)
            incomingVideoNode.updateLayout(size: layout.size)
        }
        if let outgoingVideoNode = self.outgoingVideoNode {
            if self.incomingVideoNode == nil {
                outgoingVideoNode.frame = CGRect(origin: CGPoint(), size: layout.size)
                outgoingVideoNode.updateLayout(size: layout.size, isExpanded: true, transition: transition)
            } else {
                let outgoingSize = layout.size.aspectFitted(CGSize(width: 200.0, height: 200.0))
                let outgoingFrame = CGRect(origin: CGPoint(x: layout.size.width - 16.0 - outgoingSize.width, y: buttonsOriginY - 32.0 - outgoingSize.height), size: outgoingSize)
                outgoingVideoTransition.updateFrame(node: outgoingVideoNode, frame: outgoingFrame)
                outgoingVideoNode.updateLayout(size: outgoingFrame.size, isExpanded: false, transition: outgoingVideoTransition)
            }
        }
        
        let keyTextSize = self.keyButtonNode.frame.size
        transition.updateFrame(node: self.keyButtonNode, frame: CGRect(origin: CGPoint(x: layout.size.width - keyTextSize.width - 8.0, y: navigationOffset + 8.0), size: keyTextSize))
        
        if let debugNode = self.debugNode {
            transition.updateFrame(node: debugNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        }
    }
    
    @objc func keyPressed() {
        if self.keyPreviewNode == nil, let keyText = self.keyTextData?.1, let peer = self.peer {
            let keyPreviewNode = CallControllerKeyPreviewNode(keyText: keyText, infoText: self.presentationData.strings.Call_EmojiDescription(peer.compactDisplayTitle).0.replacingOccurrences(of: "%%", with: "%"), dismiss: { [weak self] in
                if let _ = self?.keyPreviewNode {
                    self?.backPressed()
                }
            })
            
            self.containerNode.insertSubnode(keyPreviewNode, belowSubnode: self.statusNode)
            self.keyPreviewNode = keyPreviewNode
            
            if let (validLayout, _) = self.validLayout {
                keyPreviewNode.updateLayout(size: validLayout.size, transition: .immediate)
                
                self.keyButtonNode.isHidden = true
                keyPreviewNode.animateIn(from: self.keyButtonNode.frame, fromNode: self.keyButtonNode)
            }
        }
    }
    
    @objc func backPressed() {
        if let keyPreviewNode = self.keyPreviewNode {
            self.keyPreviewNode = nil
            keyPreviewNode.animateOut(to: self.keyButtonNode.frame, toNode: self.keyButtonNode, completion: { [weak self, weak keyPreviewNode] in
                self?.keyButtonNode.isHidden = false
                keyPreviewNode?.removeFromSupernode()
            })
        } else {
            self.back?()
        }
    }
    
    private var debugTapCounter: (Double, Int) = (0.0, 0)
    
    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if let _ = self.keyPreviewNode {
                self.backPressed()
            } else {
                let point = recognizer.location(in: recognizer.view)
                if self.statusNode.frame.contains(point) {
                    if self.easyDebugAccess {
                        self.presentDebugNode()
                    } else {
                        let timestamp = CACurrentMediaTime()
                        if self.debugTapCounter.0 < timestamp - 0.75 {
                            self.debugTapCounter.0 = timestamp
                            self.debugTapCounter.1 = 0
                        }
                        
                        if self.debugTapCounter.0 >= timestamp - 0.75 {
                            self.debugTapCounter.0 = timestamp
                            self.debugTapCounter.1 += 1
                        }
                        
                        if self.debugTapCounter.1 >= 10 {
                            self.debugTapCounter.1 = 0
                            
                            self.presentDebugNode()
                        }
                    }
                }
            }
        }
    }
    
    private func presentDebugNode() {
        guard self.debugNode == nil else {
            return
        }
        
        self.forceReportRating = true
        
        let debugNode = CallDebugNode(signal: self.debugInfo)
        debugNode.dismiss = { [weak self] in
            if let strongSelf = self {
                strongSelf.debugNode?.removeFromSupernode()
                strongSelf.debugNode = nil
            }
        }
        self.addSubnode(debugNode)
        self.debugNode = debugNode
        
        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        }
    }
    
    @objc func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
            case .changed:
                let offset = recognizer.translation(in: self.view).y
                var bounds = self.bounds
                bounds.origin.y = -offset
                self.bounds = bounds
            case .ended:
                let velocity = recognizer.velocity(in: self.view).y
                if abs(velocity) < 100.0 {
                    var bounds = self.bounds
                    let previous = bounds
                    bounds.origin = CGPoint()
                    self.bounds = bounds
                    self.layer.animateBounds(from: previous, to: bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                } else {
                    var bounds = self.bounds
                    let previous = bounds
                    bounds.origin = CGPoint(x: 0.0, y: velocity > 0.0 ? -bounds.height: bounds.height)
                    self.bounds = bounds
                    self.layer.animateBounds(from: previous, to: bounds, duration: 0.15, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, completion: { [weak self] _ in
                        self?.dismissedInteractively?()
                    })
                }
            case .cancelled:
                var bounds = self.bounds
                let previous = bounds
                bounds.origin = CGPoint()
                self.bounds = bounds
                self.layer.animateBounds(from: previous, to: bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
            default:
                break
        }
    }
}