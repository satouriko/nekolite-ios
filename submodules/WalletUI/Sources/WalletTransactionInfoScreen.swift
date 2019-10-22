import Foundation
import UIKit
import AppBundle
import AsyncDisplayKit
import Display
import SolidRoundedButtonNode
import SwiftSignalKit
import OverlayStatusController
import WalletCore
import AnimatedStickerNode

private func stringForFullDate(timestamp: Int32, strings: WalletStrings, dateTimeFormat: WalletPresentationDateTimeFormat) -> String {
    var t: time_t = Int(timestamp)
    var timeinfo = tm()
    localtime_r(&t, &timeinfo);
    
    let dayString = "\(timeinfo.tm_mday)"
    let yearString = "\(2000 + timeinfo.tm_year - 100)"
    let timeString = stringForShortTimestamp(hours: Int32(timeinfo.tm_hour), minutes: Int32(timeinfo.tm_min), dateTimeFormat: dateTimeFormat)
    
    let monthFormat: (String, String, String) -> (String, [(Int, NSRange)])
    switch timeinfo.tm_mon + 1 {
    case 1:
        monthFormat = strings.Wallet_Time_PreciseDate_m1
    case 2:
        monthFormat = strings.Wallet_Time_PreciseDate_m2
    case 3:
        monthFormat = strings.Wallet_Time_PreciseDate_m3
    case 4:
        monthFormat = strings.Wallet_Time_PreciseDate_m4
    case 5:
        monthFormat = strings.Wallet_Time_PreciseDate_m5
    case 6:
        monthFormat = strings.Wallet_Time_PreciseDate_m6
    case 7:
        monthFormat = strings.Wallet_Time_PreciseDate_m7
    case 8:
        monthFormat = strings.Wallet_Time_PreciseDate_m8
    case 9:
        monthFormat = strings.Wallet_Time_PreciseDate_m9
    case 10:
        monthFormat = strings.Wallet_Time_PreciseDate_m10
    case 11:
        monthFormat = strings.Wallet_Time_PreciseDate_m11
    case 12:
        monthFormat = strings.Wallet_Time_PreciseDate_m12
    default:
        return ""
    }

    return monthFormat(dayString, yearString, timeString).0
}

private enum WalletTransactionAddress {
    case list([String])
    case none
    case unknown
}

private func stringForAddress(strings: WalletStrings, address: WalletTransactionAddress) -> String {
    switch address {
        case let .list(addresses):
            return addresses.map { formatAddress($0) }.joined(separator: "\n\n")
        case .none:
            return strings.Wallet_TransactionInfo_NoAddress
        case .unknown:
            return "<unknown>"
    }
}

private func extractAddress(_ walletTransaction: WalletInfoTransaction) -> WalletTransactionAddress {
    switch walletTransaction {
    case let .completed(walletTransaction):
        let transferredValue = walletTransaction.transferredValueWithoutFees
        if transferredValue <= 0 {
            if walletTransaction.outMessages.isEmpty {
                return .none
            } else {
                var addresses: [String] = []
                for message in walletTransaction.outMessages {
                    addresses.append(message.destination)
                }
                return .list(addresses)
            }
        } else {
            if let inMessage = walletTransaction.inMessage {
                return .list([inMessage.source])
            } else {
                return .unknown
            }
        }
        return .none
    case let .pending(pending):
        return .list([pending.address])
    }
}

private func extractDescription(_ walletTransaction: WalletInfoTransaction) -> String {
    switch walletTransaction {
    case let .completed(walletTransaction):
        let transferredValue = walletTransaction.transferredValueWithoutFees
        var text = ""
        if transferredValue <= 0 {
            for message in walletTransaction.outMessages {
                if !text.isEmpty {
                    text.append("\n\n")
                }
                text.append(message.textMessage)
            }
        } else {
            if let inMessage = walletTransaction.inMessage {
                text = inMessage.textMessage
            }
        }
        return text
    case let .pending(pending):
        return String(data: pending.comment, encoding: .utf8) ?? ""
    }
}

private func messageBubbleImage(incoming: Bool, fillColor: UIColor, strokeColor: UIColor) -> UIImage {
    let diameter: CGFloat = 36.0
    let corner: CGFloat = 7.0
    
    return generateImage(CGSize(width: 42.0, height: diameter), contextGenerator: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        
        context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
        context.scaleBy(x: incoming ? 1.0 : -1.0, y: -1.0)
        context.translateBy(x: -size.width / 2.0 + 0.5, y: -size.height / 2.0 + 0.5)
        
        let lineWidth: CGFloat = 1.0
        context.setFillColor(fillColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(strokeColor.cgColor)
        
        let _ = try? drawSvgPath(context, path: "M6,17.5 C6,7.83289181 13.8350169,0 23.5,0 C33.1671082,0 41,7.83501688 41,17.5 C41,27.1671082 33.1649831,35 23.5,35 C19.2941198,35 15.4354328,33.5169337 12.4179496,31.0453367 C9.05531719,34.9894816 -2.41102995e-08,35 0,35 C5.972003,31.5499861 6,26.8616169 6,26.8616169 L6,17.5 L6,17.5 ")
        context.strokePath()
        
        let _ = try? drawSvgPath(context, path: "M6,17.5 C6,7.83289181 13.8350169,0 23.5,0 C33.1671082,0 41,7.83501688 41,17.5 C41,27.1671082 33.1649831,35 23.5,35 C19.2941198,35 15.4354328,33.5169337 12.4179496,31.0453367 C9.05531719,34.9894816 -2.41102995e-08,35 0,35 C5.972003,31.5499861 6,26.8616169 6,26.8616169 L6,17.5 L6,17.5 ")
        context.fillPath()
    })!.stretchableImage(withLeftCapWidth: incoming ? Int(corner + diameter / 2.0) : Int(diameter / 2.0), topCapHeight: Int(diameter / 2.0))
}

final class WalletTransactionInfoScreen: ViewController {
    private let context: WalletContext
    private let walletInfo: WalletInfo?
    private let walletTransaction: WalletInfoTransaction
    private var presentationData: WalletPresentationData
    
    private var previousScreenBrightness: CGFloat?
    private var displayLinkAnimator: DisplayLinkAnimator?
    private let idleTimerExtensionDisposable: Disposable
    
    public init(context: WalletContext, walletInfo: WalletInfo?, walletTransaction: WalletInfoTransaction, enableDebugActions: Bool) {
        self.context = context
        self.walletInfo = walletInfo
        self.walletTransaction = walletTransaction
        
        self.presentationData = context.presentationData
        
        let defaultTheme = self.presentationData.theme.navigationBar
        let navigationBarTheme = NavigationBarTheme(buttonColor: defaultTheme.buttonColor, disabledButtonColor: defaultTheme.disabledButtonColor, primaryTextColor: defaultTheme.primaryTextColor, backgroundColor: .clear, separatorColor: .clear, badgeBackgroundColor: defaultTheme.badgeBackgroundColor, badgeStrokeColor: defaultTheme.badgeStrokeColor, badgeTextColor: defaultTheme.badgeTextColor)
        
        self.idleTimerExtensionDisposable = context.idleTimerExtension()
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: navigationBarTheme, strings: NavigationBarStrings(back: self.presentationData.strings.Wallet_Navigation_Back, close: self.presentationData.strings.Wallet_Navigation_Close)))
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationBar?.intrinsicCanTransitionInline = false
        
        self.navigationPresentation = .flatModal
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: UIView())
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
        self.displayNode = WalletTransactionInfoScreenNode(context: self.context, presentationData: self.presentationData, walletTransaction: self.walletTransaction)
        (self.displayNode as! WalletTransactionInfoScreenNode).send = { [weak self] address in
            guard let strongSelf = self else {
                return
            }
            var randomId: Int64 = 0
            arc4random_buf(&randomId, 8)
            if let walletInfo = strongSelf.walletInfo {
                strongSelf.push(walletSendScreen(context: strongSelf.context, randomId: randomId, walletInfo: walletInfo, address: address))
                strongSelf.dismiss()
            }
        }
        (self.displayNode as! WalletTransactionInfoScreenNode).displayFeesTooltip = { [weak self] node, rect in
            guard let strongSelf = self else {
                return
            }
            var string = NSMutableAttributedString(string: "Blockchain validators collect a tiny fee for storing information about your decentralized wallet and for processing your transactions. More info", font: Font.regular(14.0), textColor: .white, paragraphAlignment: .center)
            string.addAttribute(NSAttributedString.Key.foregroundColor, value: UIColor(rgb: 0x6bb2ff), range: NSMakeRange(string.string.count - 10, 10))
            let controller = TooltipController(content: .attributedText(string), timeout: 3.0, dismissByTapOutside: true, dismissByTapOutsideSource: false, dismissImmediatelyOnLayoutUpdate: false)
            strongSelf.present(controller, in: .window(.root), with: TooltipControllerPresentationArguments(sourceViewAndRect: {
                if let strongSelf = self {
                    return (node.view, rect.insetBy(dx: 0.0, dy: -4.0))
                }
                return nil
            }))
        }
        self.displayNodeDidLoad()
    }
    
    private let measureTextNode = TextNode()
    override func preferredContentSizeForLayout(_ layout: ContainerViewLayout) -> CGSize? {
        let text = NSAttributedString(string: extractDescription(self.walletTransaction), font: Font.regular(17.0), textColor: .black)
        let makeTextLayout = TextNode.asyncLayout(self.measureTextNode)
        let (textLayout, _) = makeTextLayout(TextNodeLayoutArguments(attributedString: text, backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: layout.size.width - 36.0 * 2.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        var textHeight = textLayout.size.height
        if textHeight > 0.0 {
            textHeight += 24.0
        }
        let insets = layout.insets(options: [])
        return CGSize(width: layout.size.width, height: 428.0 + insets.bottom + textHeight)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        (self.displayNode as! WalletTransactionInfoScreenNode).containerLayoutUpdated(layout: layout, navigationHeight: self.navigationHeight, transition: transition)
    }
    
    @objc private func donePressed() {
        self.dismiss()
    }
}

private let integralFont = Font.medium(48.0)
private let fractionalFont = Font.medium(24.0)

private final class WalletTransactionInfoScreenNode: ViewControllerTracingNode {
    private let context: WalletContext
    private var presentationData: WalletPresentationData
    private let walletTransaction: WalletInfoTransaction
    private let incoming: Bool
    
    private let titleNode: ImmediateTextNode
    private let timeNode: ImmediateTextNode
    
    private let amountNode: ImmediateTextNode
    private let iconNode: AnimatedStickerNode
    private let activateArea: AccessibilityAreaNode
    private let feesNode: ImmediateTextNode
    private let feesButtonNode: ASButtonNode
    
    private let commentBackgroundNode: ASImageNode
    private let commentTextNode: ImmediateTextNode
    
    private let addressTextNode: ImmediateTextNode
    
    private let buttonNode: SolidRoundedButtonNode
    
    var send: ((String) -> Void)?
    var displayFeesTooltip: ((ASDisplayNode, CGRect) -> Void)?
  
    init(context: WalletContext, presentationData: WalletPresentationData, walletTransaction: WalletInfoTransaction) {
        self.context = context
        self.presentationData = presentationData
        self.walletTransaction = walletTransaction
        
        self.titleNode = ImmediateTextNode()
        self.titleNode.textAlignment = .center
        self.titleNode.maximumNumberOfLines = 1
        
        self.timeNode = ImmediateTextNode()
        self.timeNode.textAlignment = .center
        self.timeNode.maximumNumberOfLines = 1
        
        self.amountNode = ImmediateTextNode()
        self.amountNode.textAlignment = .center
        self.amountNode.maximumNumberOfLines = 1
        
        self.iconNode = AnimatedStickerNode()
        if let path = getAppBundle().path(forResource: "WalletIntroStatic", ofType: "tgs") {
            self.iconNode.setup(source: AnimatedStickerNodeLocalFileSource(path: path), width: 120, height: 120, mode: .direct)
            self.iconNode.visibility = true
        }
        
        self.feesNode = ImmediateTextNode()
        self.feesNode.textAlignment = .center
        self.feesNode.maximumNumberOfLines = 2
        self.feesNode.lineSpacing = 0.35
        
        self.feesButtonNode = ASButtonNode()
        
        self.commentBackgroundNode = ASImageNode()
        self.commentBackgroundNode.contentMode = .scaleToFill
        
        self.commentTextNode = ImmediateTextNode()
        self.commentTextNode.textAlignment = .natural
        self.commentTextNode.maximumNumberOfLines = 0
        
        self.addressTextNode = ImmediateTextNode()
        self.addressTextNode.maximumNumberOfLines = 4
        self.addressTextNode.textAlignment = .justified
        self.addressTextNode.lineSpacing = 0.35
        
        self.buttonNode = SolidRoundedButtonNode(title: "", icon: nil, theme: SolidRoundedButtonTheme(backgroundColor: self.presentationData.theme.setup.buttonFillColor, foregroundColor: self.presentationData.theme.setup.buttonForegroundColor), height: 50.0, cornerRadius: 10.0, gloss: false)
               
        self.activateArea = AccessibilityAreaNode()
        
        let timestamp: Int64
        let transferredValue: Int64
        switch walletTransaction {
        case let .completed(transaction):
            timestamp = transaction.timestamp
            transferredValue = transaction.transferredValueWithoutFees
        case let .pending(transaction):
            timestamp = transaction.timestamp
            transferredValue = -transaction.value
        }
        self.incoming = transferredValue > 0
        
        super.init()
        
        self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        
        self.addSubnode(self.titleNode)
        self.addSubnode(self.timeNode)
        self.addSubnode(self.amountNode)
        self.addSubnode(self.iconNode)
        self.addSubnode(self.feesNode)
        self.addSubnode(self.feesButtonNode)
        self.addSubnode(self.commentBackgroundNode)
        self.addSubnode(self.commentTextNode)
        self.addSubnode(self.addressTextNode)
        self.addSubnode(self.buttonNode)
    
        let titleFont = Font.semibold(17.0)
        let subtitleFont = Font.regular(13.0)
        let addressFont = Font.monospace(17.0)
        let textColor = self.presentationData.theme.list.itemPrimaryTextColor
        let seccondaryTextColor = self.presentationData.theme.list.itemSecondaryTextColor
        
        self.titleNode.attributedText = NSAttributedString(string: self.presentationData.strings.Wallet_TransactionInfo_Title, font: titleFont, textColor: textColor)
        
       
        self.timeNode.attributedText = NSAttributedString(string: stringForFullDate(timestamp: Int32(clamping: timestamp), strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat), font: subtitleFont, textColor: seccondaryTextColor)
                
        let amountString: String
        let amountColor: UIColor
        if transferredValue <= 0 {
            amountString = "\(formatBalanceText(-transferredValue, decimalSeparator: self.presentationData.dateTimeFormat.decimalSeparator))"
            amountColor = self.presentationData.theme.info.outgoingFundsTitleColor
        } else {
            amountString = "\(formatBalanceText(transferredValue, decimalSeparator: self.presentationData.dateTimeFormat.decimalSeparator))"
            amountColor = self.presentationData.theme.info.incomingFundsTitleColor
        }
        self.amountNode.attributedText = amountAttributedString(amountString, integralFont: integralFont, fractionalFont: fractionalFont, color: amountColor)
        
        var feesString: String = ""
        if case let .completed(transaction) = walletTransaction {
            if transaction.storageFee != 0 {
                feesString.append(formatBalanceText(transaction.storageFee, decimalSeparator: presentationData.dateTimeFormat.decimalSeparator) + " storage fee")
            }
            if transaction.otherFee != 0 {
                if !feesString.isEmpty {
                    feesString.append("\n")
                }
                feesString.append(formatBalanceText(transaction.otherFee, decimalSeparator: presentationData.dateTimeFormat.decimalSeparator) + " transaction fee")
            }
            
            if !feesString.isEmpty {
                feesString.append("(?)")
            }
        }
        self.feesNode.attributedText = NSAttributedString(string: feesString, font: subtitleFont, textColor: seccondaryTextColor)
        
        self.feesButtonNode.addTarget(self, action: #selector(feesPressed), forControlEvents: .touchUpInside)
        
        self.commentBackgroundNode.image = messageBubbleImage(incoming: transferredValue > 0, fillColor: UIColor(rgb: 0xf1f1f5), strokeColor: UIColor(rgb: 0xf1f1f5))
        self.commentTextNode.attributedText = NSAttributedString(string: extractDescription(walletTransaction), font: Font.regular(17.0), textColor: .black)
        
        let address = extractAddress(walletTransaction)
        var singleAddress: String?
        if case let .list(list) = address, list.count == 1 {
            singleAddress = list.first
        }
        
        if let address = singleAddress {
            self.addressTextNode.attributedText = NSAttributedString(string: formatAddress(address), font: addressFont, textColor: textColor, paragraphAlignment: .justified)
            self.buttonNode.title = "Send Grams to This Address"

            self.buttonNode.pressed = { [weak self] in
                self?.send?(address)
            }
        }
    }
    
    @objc private func feesPressed() {
        self.displayFeesTooltip?(self.feesNode, self.feesNode.bounds)
    }

    func containerLayoutUpdated(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        var insets = layout.insets(options: [])
        insets.top += navigationHeight
        let inset: CGFloat = 22.0
        
        let titleSize = self.titleNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        let titleFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - titleSize.width) / 2.0), y: 10.0), size: titleSize)
        transition.updateFrame(node: self.titleNode, frame: titleFrame)
        
        let subtitleSize = self.timeNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        let subtitleFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - subtitleSize.width) / 2.0), y: titleFrame.maxY + 1.0), size: subtitleSize)
        transition.updateFrame(node: self.timeNode, frame: subtitleFrame)
        
        let amountSize = self.amountNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        let amountFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - amountSize.width) / 2.0) + 18.0, y: 90.0), size: amountSize)
        transition.updateFrame(node: self.amountNode, frame: amountFrame)
        
        let iconSize = CGSize(width: 50.0, height: 50.0)
        let iconFrame = CGRect(origin: CGPoint(x: amountFrame.minX - iconSize.width, y: amountFrame.minY), size: iconSize)
        self.iconNode.updateLayout(size: iconFrame.size)
        self.iconNode.frame = iconFrame
        
        let feesSize = self.feesNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        let feesFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - feesSize.width) / 2.0), y: amountFrame.maxY + 8.0), size: feesSize)
        transition.updateFrame(node: self.feesNode, frame: feesFrame)
        transition.updateFrame(node: self.feesButtonNode, frame: feesFrame)
        
        let commentSize = self.commentTextNode.updateLayout(CGSize(width: layout.size.width - 36.0 * 2.0, height: CGFloat.greatestFiniteMagnitude))
        let commentFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - commentSize.width) / 2.0), y: amountFrame.maxY + 84.0), size: CGSize(width: commentSize.width, height: commentSize.height))
        transition.updateFrame(node: self.commentTextNode, frame: commentFrame)
        
        var commentBackgroundFrame = commentSize.width > 0.0 ? commentFrame.insetBy(dx: -11.0, dy: -7.0) : CGRect()
        commentBackgroundFrame.size.width += 7.0
        if self.incoming {
            commentBackgroundFrame.origin.x -= 7.0
        }
        transition.updateFrame(node: self.commentBackgroundNode, frame: commentBackgroundFrame)
        
        let buttonSideInset: CGFloat = 16.0
        let bottomInset = insets.bottom + 10.0
        let buttonWidth = layout.size.width - buttonSideInset * 2.0
        let buttonHeight: CGFloat = 50.0
        
        let buttonFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - buttonWidth) / 2.0), y: layout.size.height - bottomInset - buttonHeight), size: CGSize(width: buttonWidth, height: buttonHeight))
        transition.updateFrame(node: self.buttonNode, frame: buttonFrame)
        self.buttonNode.updateLayout(width: buttonFrame.width, transition: transition)
        
        let addressSize = self.addressTextNode.updateLayout(CGSize(width: layout.size.width - inset * 2.0, height: CGFloat.greatestFiniteMagnitude))
        transition.updateFrame(node: self.addressTextNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - addressSize.width) / 2.0), y: buttonFrame.minY - addressSize.height - 44.0), size: addressSize))
    }
}