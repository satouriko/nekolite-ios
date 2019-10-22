import Foundation
import UIKit
import SwiftSignalKit
import AppBundle
import AsyncDisplayKit
import Display
import QrCode
import AnimatedStickerNode
import SolidRoundedButtonNode

private func shareInvoiceQrCode(context: WalletContext, invoice: String) {
    let _ = (qrCode(string: invoice, color: .black, backgroundColor: .white, icon: .custom(UIImage(bundleImageName: "Wallet/QrGem")))
    |> map { generator -> UIImage? in
        let imageSize = CGSize(width: 768.0, height: 768.0)
        let context = generator(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), scale: 1.0))
        return context?.generateImage()
    }
    |> deliverOnMainQueue).start(next: { image in
        guard let image = image else {
            return
        }
        
        let activityController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        context.presentNativeController(activityController)
    })
}

public enum WalletReceiveScreenMode {
    case receive(address: String)
    case invoice(address: String, amount: String?, comment: String?)
    
    var address: String {
        switch self {
            case let .receive(address), let .invoice(address, _, _):
                return address
        }
    }
}

final class WalletReceiveScreen: ViewController {
    private let context: WalletContext
    private let mode: WalletReceiveScreenMode
    private var presentationData: WalletPresentationData
    
    private var previousScreenBrightness: CGFloat?
    private var displayLinkAnimator: DisplayLinkAnimator?
    private let idleTimerExtensionDisposable: Disposable
    
    public init(context: WalletContext, mode: WalletReceiveScreenMode) {
        self.context = context
        self.mode = mode
        
        self.presentationData = context.presentationData
        
        let defaultTheme = self.presentationData.theme.navigationBar
        let navigationBarTheme = NavigationBarTheme(buttonColor: defaultTheme.buttonColor, disabledButtonColor: defaultTheme.disabledButtonColor, primaryTextColor: defaultTheme.primaryTextColor, backgroundColor: .clear, separatorColor: .clear, badgeBackgroundColor: defaultTheme.badgeBackgroundColor, badgeStrokeColor: defaultTheme.badgeStrokeColor, badgeTextColor: defaultTheme.badgeTextColor)
        
        self.idleTimerExtensionDisposable = context.idleTimerExtension()
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: navigationBarTheme, strings: NavigationBarStrings(back: self.presentationData.strings.Wallet_Navigation_Back, close: self.presentationData.strings.Wallet_Navigation_Close)))
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationBar?.intrinsicCanTransitionInline = false
        
        if case .receive = mode {
            self.navigationPresentation = .flatModal
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: UIView())
        }
    
        self.title = self.presentationData.strings.Wallet_Receive_Title
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Wallet_Navigation_Back, style: .plain, target: nil, action: nil)
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Wallet_Navigation_Done, style: .done, target: self, action: #selector(self.donePressed))
    }
    
    deinit {
        self.idleTimerExtensionDisposable.dispose()
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadDisplayNode() {
        self.displayNode = WalletReceiveScreenNode(context: self.context, presentationData: self.presentationData, mode: self.mode)
        (self.displayNode as! WalletReceiveScreenNode).openCreateInvoice = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            self?.push(walletCreateInvoiceScreen(context: strongSelf.context, address: strongSelf.mode.address))
        }
        self.displayNodeDidLoad()
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let screenBrightness = UIScreen.main.brightness
        if screenBrightness < 0.85 {
            self.previousScreenBrightness = screenBrightness
            self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.5, from: screenBrightness, to: 0.85, update: { value in
                UIScreen.main.brightness = value
            }, completion: {
                self.displayLinkAnimator = nil
            })
        }
    }
    
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        let screenBrightness = UIScreen.main.brightness
        if let previousScreenBrightness = self.previousScreenBrightness, screenBrightness > previousScreenBrightness {
            self.displayLinkAnimator = DisplayLinkAnimator(duration: 0.2, from: screenBrightness, to: previousScreenBrightness, update: { value in
                UIScreen.main.brightness = value
            }, completion: {
                self.displayLinkAnimator = nil
            })
        }
    }

    override func preferredContentSizeForLayout(_ layout: ContainerViewLayout) -> CGSize? {
        return CGSize(width: layout.size.width, height: layout.size.height - 174.0)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        (self.displayNode as! WalletReceiveScreenNode).containerLayoutUpdated(layout: layout, navigationHeight: self.navigationHeight, transition: transition)
    }
    
    @objc private func donePressed() {
        if let navigationController = self.navigationController as? NavigationController {
            var controllers = navigationController.viewControllers
            controllers = controllers.filter { controller in
                if controller is WalletReceiveScreen {
                    return false
                }
                if controller is WalletCreateInvoiceScreen {
                    return false
                }
                return true
            }
            navigationController.setViewControllers(controllers, animated: true)
        }
    }
}

private func urlForMode(_ mode: WalletReceiveScreenMode) -> String {
    switch mode {
        case let .receive(address):
            return walletInvoiceUrl(address: address)
        case let .invoice(address, amount, comment):
            return walletInvoiceUrl(address: address, amount: amount, comment: comment)
    }
}

private final class WalletReceiveScreenNode: ViewControllerTracingNode {
    private let context: WalletContext
    private var presentationData: WalletPresentationData
    private let mode: WalletReceiveScreenMode
    
    private let textNode: ImmediateTextNode
    
    private let qrButtonNode: HighlightTrackingButtonNode
    private let qrImageNode: TransformImageNode
    private let qrIconNode: AnimatedStickerNode
    
    private let urlTextNode: ImmediateTextNode
    
    private let buttonNode: SolidRoundedButtonNode
    private let secondaryButtonNode: HighlightableButtonNode
    
    var openCreateInvoice: (() -> Void)?
  
    init(context: WalletContext, presentationData: WalletPresentationData, mode: WalletReceiveScreenMode) {
        self.context = context
        self.presentationData = presentationData
        self.mode = mode
        
        self.textNode = ImmediateTextNode()
        self.textNode.textAlignment = .center
        self.textNode.maximumNumberOfLines = 3
        
        self.qrImageNode = TransformImageNode()
        self.qrImageNode.clipsToBounds = true
        self.qrImageNode.cornerRadius = 14.0
            
        self.qrIconNode = AnimatedStickerNode()
        if let path = getAppBundle().path(forResource: "WalletIntroStatic", ofType: "tgs") {
            self.qrIconNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 240, height: 240, mode: .direct)
            self.qrIconNode.visibility = true
        }
        
        self.qrButtonNode = HighlightTrackingButtonNode()
        
        self.urlTextNode = ImmediateTextNode()
        self.urlTextNode.maximumNumberOfLines = 4
        self.urlTextNode.textAlignment = .justified
        self.urlTextNode.lineSpacing = 0.35
        
        self.buttonNode = SolidRoundedButtonNode(title: "", icon: nil, theme: SolidRoundedButtonTheme(backgroundColor: self.presentationData.theme.setup.buttonFillColor, foregroundColor: self.presentationData.theme.setup.buttonForegroundColor), height: 50.0, cornerRadius: 10.0, gloss: false)
        
        self.secondaryButtonNode = HighlightableButtonNode()
        
        super.init()
        
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        self.addSubnode(self.textNode)
        self.addSubnode(self.qrImageNode)
        self.addSubnode(self.qrIconNode)
        self.addSubnode(self.qrButtonNode)
        self.addSubnode(self.urlTextNode)
        self.addSubnode(self.buttonNode)
        self.addSubnode(self.secondaryButtonNode)
        
        self.qrImageNode.setSignal(qrCode(string: urlForMode(mode), color: .black, backgroundColor: .white, icon: .cutout), attemptSynchronously: true)
        
        self.qrButtonNode.addTarget(self, action: #selector(self.qrPressed), forControlEvents: .touchUpInside)
        self.qrButtonNode.highligthedChanged = { [weak self] highlighted in
            guard let strongSelf = self else {
                return
            }
            if highlighted {
                strongSelf.qrImageNode.alpha = 0.4
                strongSelf.qrIconNode.alpha = 0.4
            } else {
                strongSelf.qrImageNode.layer.animateAlpha(from: strongSelf.qrImageNode.alpha, to: 1.0, duration: 0.2)
                strongSelf.qrIconNode.layer.animateAlpha(from: strongSelf.qrIconNode.alpha, to: 1.0, duration: 0.2)
                strongSelf.qrImageNode.alpha = 1.0
                strongSelf.qrIconNode.alpha = 1.0
            }
        }
        
        let textFont = Font.regular(16.0)
        let addressFont = Font.monospace(17.0)
        let textColor = self.presentationData.theme.list.itemPrimaryTextColor
        let secondaryTextColor = self.presentationData.theme.list.itemSecondaryTextColor
        let url = urlForMode(self.mode)
        switch self.mode {
            case let .receive(address):
                self.textNode.attributedText = NSAttributedString(string: self.presentationData.strings.Wallet_Receive_ShareUrlInfo, font: textFont, textColor: secondaryTextColor)
                self.urlTextNode.attributedText = NSAttributedString(string: formatAddress(url + " "), font: addressFont, textColor: textColor, paragraphAlignment: .justified)
                self.buttonNode.title = self.presentationData.strings.Wallet_Receive_ShareAddress
                self.secondaryButtonNode.setTitle(self.presentationData.strings.Wallet_Receive_CreateInvoice, with: Font.regular(17.0), with: self.presentationData.theme.list.itemAccentColor, for: .normal)
            case let .invoice(address, amount, comment):
                self.textNode.attributedText = NSAttributedString(string: self.presentationData.strings.Wallet_Receive_ShareUrlInfo, font: textFont, textColor: secondaryTextColor, paragraphAlignment: .center)
                
                let sliced = String(url.enumerated().map { $0 > 0 && $0 % 32 == 0 ? ["\n", $1] : [$1]}.joined())
                self.urlTextNode.attributedText = NSAttributedString(string: sliced, font: addressFont, textColor: textColor, paragraphAlignment: .justified)
                self.buttonNode.title = self.presentationData.strings.Wallet_Receive_ShareInvoiceUrl
        }
        
        self.buttonNode.pressed = {
            context.shareUrl(url)
        }
        self.secondaryButtonNode.addTarget(self, action: #selector(createInvoicePressed), forControlEvents: .touchUpInside)
    }
    
    @objc private func qrPressed() {
        shareInvoiceQrCode(context: self.context, invoice: urlForMode(self.mode))
    }
    
    @objc private func createInvoicePressed() {
        self.openCreateInvoice?()
    }
    
    func containerLayoutUpdated(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        var insets = layout.insets(options: [])
        insets.top += navigationHeight
        let inset: CGFloat = 22.0
        
        let textSize = self.textNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        let textFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - textSize.width) / 2.0), y: insets.top + 24.0), size: textSize)
        transition.updateFrame(node: self.textNode, frame: textFrame)
        
        let makeImageLayout = self.qrImageNode.asyncLayout()
        
        let imageSide: CGFloat = 215.0
        var imageSize = CGSize(width: imageSide, height: imageSide)
        let imageApply = makeImageLayout(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), emptyColor: nil))
        
        let _ = imageApply()
        
        let imageFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - imageSize.width) / 2.0), y: textFrame.maxY + 20.0), size: imageSize)
        transition.updateFrame(node: self.qrImageNode, frame: imageFrame)
        transition.updateFrame(node: self.qrButtonNode, frame: imageFrame)
        
        let iconSide = floor(imageSide * 0.24)
        let iconSize = CGSize(width: iconSide, height: iconSide)
        self.qrIconNode.updateLayout(size: iconSize)
        transition.updateBounds(node: self.qrIconNode, bounds: CGRect(origin: CGPoint(), size: iconSize))
        transition.updatePosition(node: self.qrIconNode, position: imageFrame.center.offsetBy(dx: 0.0, dy: -1.0))
        
        let urlTextSize = self.urlTextNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        transition.updateFrame(node: self.urlTextNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - urlTextSize.width) / 2.0), y: imageFrame.maxY + 25.0), size: urlTextSize))
        
        let buttonSideInset: CGFloat = 16.0
        let bottomInset = insets.bottom + 10.0
        let buttonWidth = layout.size.width - buttonSideInset * 2.0
        let buttonHeight: CGFloat = 50.0
        
        var buttonOffset: CGFloat = 0.0
        if let _ = self.secondaryButtonNode.attributedTitle(for: .normal) {
            buttonOffset = -60.0
            self.secondaryButtonNode.frame = CGRect(x: floor((layout.size.width - buttonWidth) / 2.0), y: layout.size.height - bottomInset - buttonHeight, width: buttonWidth, height: buttonHeight)
        }
        
        let buttonFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - buttonWidth) / 2.0), y: layout.size.height - bottomInset - buttonHeight + buttonOffset), size: CGSize(width: buttonWidth, height: buttonHeight))
        transition.updateFrame(node: self.buttonNode, frame: buttonFrame)
        self.buttonNode.updateLayout(width: buttonFrame.width, transition: transition)
    }
}