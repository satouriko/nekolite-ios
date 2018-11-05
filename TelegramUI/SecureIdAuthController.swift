import Foundation
import Display
import AsyncDisplayKit
import SwiftSignalKit
import Postbox
import TelegramCore

public enum SecureIdRequestResult: String {
    case success = "success"
    case cancel = "cancel"
    case error = "error"
}

public func secureIdCallbackUrl(with baseUrl: String, peerId: PeerId, result: SecureIdRequestResult, parameters: [String : String]) -> String {
    var query = (parameters.compactMap({ (key, value) -> String in
        return "\(key)=\(value)"
    }) as Array).joined(separator: "&")
    
    if !query.isEmpty {
        query = "?" + query
    }
    
    let url: String
    if baseUrl.hasPrefix("tgbot") {
        url = "tgbot\(peerId.id)://passport/" + result.rawValue + query
    } else {
        url = baseUrl + (baseUrl.range(of: "?") != nil ? "&" : "?") + "tg_passport=" + result.rawValue + query
    }
    return url
}

final class SecureIdAuthControllerInteraction {
    let updateState: ((SecureIdAuthControllerState) -> SecureIdAuthControllerState) -> Void
    let present: (ViewController, Any?) -> Void
    let checkPassword: (String) -> Void
    let openPasswordHelp: () -> Void
    let setupPassword: () -> Void
    let grant: () -> Void
    let openUrl: (String) -> Void
    let openMention: (TelegramPeerMention) -> Void
    let deleteAll: () -> Void
    
    fileprivate init(updateState: @escaping ((SecureIdAuthControllerState) -> SecureIdAuthControllerState) -> Void, present: @escaping (ViewController, Any?) -> Void, checkPassword: @escaping (String) -> Void, openPasswordHelp: @escaping () -> Void, setupPassword: @escaping () -> Void, grant: @escaping () -> Void, openUrl: @escaping (String) -> Void, openMention: @escaping (TelegramPeerMention) -> Void, deleteAll: @escaping () -> Void) {
        self.updateState = updateState
        self.present = present
        self.checkPassword = checkPassword
        self.openPasswordHelp = openPasswordHelp
        self.setupPassword = setupPassword
        self.grant = grant
        self.openUrl = openUrl
        self.openMention = openMention
        self.deleteAll = deleteAll
    }
}

enum SecureIdAuthControllerMode {
    case form(peerId: PeerId, scope: String, publicKey: String, callbackUrl: String, opaquePayload: Data, opaqueNonce: Data)
    case list
}

final class SecureIdAuthController: ViewController {
    private var controllerNode: SecureIdAuthControllerNode {
        return self.displayNode as! SecureIdAuthControllerNode
    }
    
    private let account: Account
    private var presentationData: PresentationData
    private let mode: SecureIdAuthControllerMode
    
    private var didPlayPresentationAnimation = false
    
    private let challengeDisposable = MetaDisposable()
    private let authenthicateDisposable = MetaDisposable()
    private var formDisposable: Disposable?
    private let deleteDisposable = MetaDisposable()
    private let recoveryDisposable = MetaDisposable()
    
    private var state: SecureIdAuthControllerState
    
    private let hapticFeedback = HapticFeedback()
    
    init(account: Account, mode: SecureIdAuthControllerMode) {
        self.account = account
        self.presentationData = account.telegramApplicationContext.currentPresentationData.with { $0 }
        
        self.mode = mode
        
        switch mode {
            case .form:
                self.state = .form(SecureIdAuthControllerFormState(twoStepEmail: nil, encryptedFormData: nil, formData: nil, verificationState: nil, removingValues: false))
            case .list:
                self.state = .list(SecureIdAuthControllerListState(accountPeer: nil, twoStepEmail: nil, verificationState: nil, encryptedValues: nil, primaryLanguageByCountry: [:], values: nil, removingValues: false))
        }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBar.style.style
        
        self.title = self.presentationData.strings.Passport_Title
        switch mode {
            case .form:
                self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
            case .list:
                self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Done, style: .done, target: self, action: #selector(self.cancelPressed))
        }
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: PresentationResourcesRootController.navigationInfoIcon(self.presentationData.theme), style: .plain, target: self, action: #selector(self.infoPressed))
        
        self.challengeDisposable.set((twoStepAuthData(account.network)
        |> deliverOnMainQueue).start(next: { [weak self] data in
            if let strongSelf = self {
                let storedPassword = strongSelf.account.telegramApplicationContext.getStoredSecureIdPassword()
                if data.currentPasswordDerivation != nil, let storedPassword = storedPassword {
                    strongSelf.authenthicateDisposable.set((accessSecureId(network: strongSelf.account.network, password: storedPassword)
                    |> deliverOnMainQueue).start(next: { context in
                        guard let strongSelf = self, strongSelf.state.verificationState == nil else {
                            return
                        }
                        
                        strongSelf.updateState(animated: true, { state in
                            var state = state
                            state.verificationState = .verified(context.context)
                            state.twoStepEmail = !context.settings.email.isEmpty ? context.settings.email : nil
                            switch state {
                                case var .form(form):
                                    form.formData = form.encryptedFormData.flatMap({ decryptedSecureIdForm(context: context.context, form: $0.form) })
                                    state = .form(form)
                                case var .list(list):
                                    list.values = list.encryptedValues.flatMap({ decryptedAllSecureIdValues(context: context.context, encryptedValues: $0) })
                                    state = .list(list)
                            }
                            return state
                        })
                    }, error: { [weak self] error in
                        guard let strongSelf = self else {
                            return
                        }
                        if strongSelf.state.verificationState == nil {
                            strongSelf.updateState(animated: true, { state in
                                var state = state
                                state.verificationState = .passwordChallenge(hint: data.currentHint ?? "", state: .none, hasRecoveryEmail: data.hasRecovery)
                                return state
                            })
                        }
                    }))
                } else {
                    strongSelf.updateState { state in
                        var state = state
                        if data.currentPasswordDerivation != nil {
                            state.verificationState = .passwordChallenge(hint: data.currentHint ?? "", state: .none, hasRecoveryEmail: data.hasRecovery)
                        } else {
                            state.verificationState = .noChallenge(data.unconfirmedEmailPattern)
                        }
                        return state
                    }
                }
            }
        }))
        
        let handleError: (Any, String?, PeerId?) -> Void = { [weak self] error, callbackUrl, peerId in
            if let strongSelf = self {
                var passError: String?
                var appUpdateRequired = false
                switch error {
                    case let error as RequestSecureIdFormError:
                        if case let .serverError(error) = error, ["BOT_INVALID", "PUBLIC_KEY_REQUIRED", "PUBLIC_KEY_INVALID", "SCOPE_EMPTY", "PAYLOAD_EMPTY", "NONCE_EMPTY"].contains(error) {
                            passError = error
                        } else if case .versionOutdated = error {
                            appUpdateRequired = true
                        }
                        break
                    case let error as GetAllSecureIdValuesError:
                        if case .versionOutdated = error {
                            appUpdateRequired = true
                        }
                        break
                    default:
                        break
                }
                
                if appUpdateRequired {
                    let errorText = strongSelf.presentationData.strings.Passport_UpdateRequiredError
                    strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: strongSelf.presentationData.theme), title: nil, text: errorText, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_NotNow, action: {}), TextAlertAction(type: .genericAction, title: strongSelf.presentationData.strings.Application_Update, action: {
                        account.telegramApplicationContext.applicationBindings.openAppStorePage()
                    })]), in: .window(.root))
                } else if let callbackUrl = callbackUrl, let peerId = peerId {
                    let errorText = strongSelf.presentationData.strings.Login_UnknownError
                    strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: strongSelf.presentationData.theme), title: nil, text: errorText, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {
                        if let error = passError {
                            strongSelf.openUrl(secureIdCallbackUrl(with: callbackUrl, peerId: peerId, result: .error, parameters: ["error": error]))
                        }
                    })]), in: .window(.root))
                }
                strongSelf.dismiss()
            }
        }
        
        switch self.mode {
            case let .form(peerId, scope, publicKey, callbackUrl, _, _):
                self.formDisposable = (combineLatest(requestSecureIdForm(postbox: account.postbox, network: account.network, peerId: peerId, scope: scope, publicKey: publicKey), secureIdConfiguration(postbox: account.postbox, network: account.network) |> introduceError(RequestSecureIdFormError.self))
                |> mapToSignal { form, configuration -> Signal<SecureIdEncryptedFormData, RequestSecureIdFormError> in
                    return account.postbox.transaction { transaction -> Signal<SecureIdEncryptedFormData, RequestSecureIdFormError> in
                        guard let accountPeer = transaction.getPeer(account.peerId), let servicePeer = transaction.getPeer(form.peerId) else {
                            return .fail(.generic)
                        }
                        
                        let primaryLanguageByCountry = configuration.nativeLanguageByCountry
                        return .single(SecureIdEncryptedFormData(form: form, primaryLanguageByCountry: primaryLanguageByCountry, accountPeer: accountPeer, servicePeer: servicePeer))
                    }
                    |> mapError { _ in return RequestSecureIdFormError.generic }
                    |> switchToLatest
                }
                |> deliverOnMainQueue).start(next: { [weak self] formData in
                    if let strongSelf = self {
                        strongSelf.updateState { state in
                            var state = state
                            switch state {
                                case var .form(form):
                                    form.encryptedFormData = formData
                                    state = .form(form)
                                case .list:
                                    break
                            }
                            return state
                        }
                    }
                }, error: { error in
                    handleError(error, callbackUrl, peerId)
                })
            case .list:
                self.formDisposable = (combineLatest(getAllSecureIdValues(network: self.account.network), secureIdConfiguration(postbox: account.postbox, network: account.network) |> introduceError(GetAllSecureIdValuesError.self), account.postbox.transaction { transaction -> Signal<Peer, GetAllSecureIdValuesError> in
                    guard let accountPeer = transaction.getPeer(account.peerId) else {
                        return .fail(.generic)
                    }
                    
                    return .single(accountPeer)
                    }
                    |> mapError { _ in return GetAllSecureIdValuesError.generic }
                    |> switchToLatest)
                |> deliverOnMainQueue).start(next: { [weak self] values, configuration, accountPeer in
                    if let strongSelf = self {
                        strongSelf.updateState { state in
                            let state = state
                            let primaryLanguageByCountry = configuration.nativeLanguageByCountry
                            
                            switch state {
                                case .form:
                                    break
                                case var .list(list):
                                    list.accountPeer = accountPeer
                                    list.primaryLanguageByCountry = primaryLanguageByCountry
                                    list.encryptedValues = values
                                    return .list(list)
                            }
                            return state
                        }
                    }
                }, error: { error in
                    handleError(error, nil, nil)
                })
        }
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.challengeDisposable.dispose()
        self.authenthicateDisposable.dispose()
        self.formDisposable?.dispose()
        self.deleteDisposable.dispose()
        self.recoveryDisposable.dispose()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !self.didPlayPresentationAnimation {
            self.didPlayPresentationAnimation = true
            self.controllerNode.animateIn()
        }
    }
    
    override func dismiss(completion: (() -> Void)? = nil) {
        self.controllerNode.animateOut(completion: { [weak self] in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
            completion?()
        })
    }
    
    override func loadDisplayNode() {
        let interaction = SecureIdAuthControllerInteraction(updateState: { [weak self] f in
            self?.updateState(f)
        }, present: { [weak self] c, a in
            self?.present(c, in: .window(.root), with: a)
        }, checkPassword: { [weak self] password in
            self?.checkPassword(password: password, inBackground: false, completion: {})
        }, openPasswordHelp: { [weak self] in
            self?.openPasswordHelp()
        }, setupPassword: { [weak self] in
            self?.setupPassword()
        }, grant: { [weak self] in
            self?.grantAccess()
        }, openUrl: { [weak self] url in
            if let strongSelf = self {
                openExternalUrl(account: strongSelf.account, url: url, presentationData: strongSelf.presentationData, applicationContext: strongSelf.account.telegramApplicationContext, navigationController: strongSelf.navigationController as? NavigationController, dismissInput: {
                    self?.view.endEditing(true)
                })
            }
        }, openMention: { [weak self] mention in
            guard let strongSelf = self else {
                return
            }
            let _ = (strongSelf.account.postbox.loadedPeerWithId(mention.peerId)
            |> deliverOnMainQueue).start(next: { peer in
                guard let strongSelf = self else {
                    return
                }
                if let infoController = peerInfoController(account: strongSelf.account, peer: peer) {
                    (strongSelf.navigationController as? NavigationController)?.pushViewController(infoController)
                }
            })
        }, deleteAll: { [weak self] in
            guard let strongSelf = self, case let .list(list) = strongSelf.state, let values = list.values else {
                return
            }
            
            let item = UIBarButtonItem(customDisplayNode: ProgressNavigationButtonNode(theme: strongSelf.presentationData.theme))
            strongSelf.navigationItem.rightBarButtonItem = item
            strongSelf.deleteDisposable.set((deleteSecureIdValues(network: strongSelf.account.network, keys: Set(values.map({ $0.value.key })))
            |> deliverOnMainQueue).start(completed: {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.navigationItem.rightBarButtonItem = UIBarButtonItem(image: PresentationResourcesRootController.navigationInfoIcon(strongSelf.presentationData.theme), style: .plain, target: self, action: #selector(strongSelf.infoPressed))
                strongSelf.updateState { state in
                    if case var .list(list) = state {
                        list.values = []
                        return .list(list)
                    }
                    return state
                }
            }))
        })
        
        self.displayNode = SecureIdAuthControllerNode(account: self.account, presentationData: presentationData, requestLayout: { [weak self] transition in
            self?.requestLayout(transition: transition)
        }, interaction: interaction)
        self.controllerNode.updateState(self.state, transition: .immediate)
    }
    
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationHeight, transition: transition)
    }
    
    private func updateState(animated: Bool = true, _ f: (SecureIdAuthControllerState) -> SecureIdAuthControllerState) {
        let state = f(self.state)
        if state != self.state {
            var previousHadProgress = false
            if let verificationState = self.state.verificationState, case .passwordChallenge(_, .checking, _) = verificationState {
                previousHadProgress = true
            }
            if self.state.removingValues {
                previousHadProgress = true
            }
            var updatedHasProgress = false
            if let verificationState = state.verificationState, case .passwordChallenge(_, .checking, _) = verificationState {
                updatedHasProgress = true
            }
            if state.removingValues {
                updatedHasProgress = true
            }
            
            self.state = state
            if self.isNodeLoaded {
                self.controllerNode.updateState(self.state, transition: animated ? .animated(duration: 0.3, curve: .spring) : .immediate)
            }
            
            if previousHadProgress != updatedHasProgress {
                if updatedHasProgress {
                    let item = UIBarButtonItem(customDisplayNode: ProgressNavigationButtonNode(theme: self.presentationData.theme))
                    self.navigationItem.rightBarButtonItem = item
                } else {
                    self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: PresentationResourcesRootController.navigationInfoIcon(self.presentationData.theme), style: .plain, target: self, action: #selector(self.infoPressed))
                }
            }
        }
    }
    
    private func openUrl(_ url: String) {
        openExternalUrl(account: self.account, url: url, forceExternal: true, presentationData: self.presentationData, applicationContext: self.account.telegramApplicationContext, navigationController: nil, dismissInput: { [weak self] in
            self?.view.endEditing(true)
        })
    }
    
    @objc private func cancelPressed() {
        self.dismiss()
        
        if case let .form(reqForm) = self.mode {
            self.openUrl(secureIdCallbackUrl(with: reqForm.callbackUrl, peerId: reqForm.peerId, result: .cancel, parameters: [:]))
        }
    }
    
    @objc private func checkPassword(password: String, inBackground: Bool, completion: @escaping () -> Void) {
        if let verificationState = self.state.verificationState, case let .passwordChallenge(hint, challengeState, hasRecoveryEmail) = verificationState {
            switch challengeState {
                case .none, .invalid:
                    break
                case .checking:
                    return
            }
            self.updateState(animated: !inBackground, { state in
                var state = state
                state.verificationState = .passwordChallenge(hint: hint, state: .checking, hasRecoveryEmail: hasRecoveryEmail)
                return state
            })
            self.challengeDisposable.set((accessSecureId(network: self.account.network, password: password)
            |> deliverOnMainQueue).start(next: { [weak self] context in
                guard let strongSelf = self, let verificationState = strongSelf.state.verificationState, case .passwordChallenge(_, .checking, _) = verificationState else {
                    return
                }
                strongSelf.account.telegramApplicationContext.storeSecureIdPassword(password: password)
                strongSelf.updateState(animated: !inBackground, { state in
                    var state = state
                    state.verificationState = .verified(context.context)
                    state.twoStepEmail = !context.settings.email.isEmpty ? context.settings.email : nil
                    switch state {
                        case var .form(form):
                            form.formData = form.encryptedFormData.flatMap({ decryptedSecureIdForm(context: context.context, form: $0.form) })
                            state = .form(form)
                        case var .list(list):
                            list.values = list.encryptedValues.flatMap({ decryptedAllSecureIdValues(context: context.context, encryptedValues: $0) })
                            state = .list(list)
                    }
                    return state
                })
                completion()
            }, error: { [weak self] error in
                guard let strongSelf = self else {
                    return
                }
                let errorText: String
                switch error {
                    case let .passwordError(passwordError):
                        switch passwordError {
                            case .invalidPassword:
                                errorText = strongSelf.presentationData.strings.LoginPassword_InvalidPasswordError
                            case .limitExceeded:
                                errorText = strongSelf.presentationData.strings.LoginPassword_FloodError
                            case .generic:
                                errorText = strongSelf.presentationData.strings.Login_UnknownError
                        }
                    case .generic:
                        errorText = strongSelf.presentationData.strings.Login_UnknownError
                    case .secretPasswordMismatch:
                        errorText = strongSelf.presentationData.strings.Login_UnknownError
                }
                strongSelf.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: strongSelf.presentationData.theme), title: nil, text: errorText, actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                
                if let verificationState = strongSelf.state.verificationState, case let .passwordChallenge(hint, .checking, hasRecoveryEmail) = verificationState {
                    strongSelf.updateState(animated: !inBackground, { state in
                        var state = state
                        state.verificationState = .passwordChallenge(hint: hint, state: .invalid, hasRecoveryEmail: hasRecoveryEmail)
                        return state
                    })
                }
                completion()
            }))
        }
    }
    
    private func openPasswordHelp() {
        guard let verificationState = self.state.verificationState, case let .passwordChallenge(passwordChallenge) = verificationState else {
            return
        }
        switch passwordChallenge.state {
            case .checking:
                return
            case .none, .invalid:
                break
        }
        
        if passwordChallenge.hasRecoveryEmail {
            self.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: self.presentationData.theme), title: self.presentationData.strings.Passport_ForgottenPassword, text: self.presentationData.strings.Passport_PasswordReset, actions: [TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}), TextAlertAction(type: .defaultAction, title: presentationData.strings.Login_ResetAccountProtected_Reset, action: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.recoveryDisposable.set((requestTwoStepVerificationPasswordRecoveryCode(network: strongSelf.account.network)
                |> deliverOnMainQueue).start(next: { emailPattern in
                    guard let strongSelf = self else {
                        return
                    }
                    var completionImpl: (() -> Void)?
                    let controller = resetPasswordController(account: strongSelf.account, emailPattern: emailPattern, completion: {
                        completionImpl?()
                    })
                    completionImpl = { [weak controller] in
                        guard let strongSelf = self else {
                            return
                        }
                        strongSelf.updateState(animated: false, { state in
                            var state = state
                            state.verificationState = .noChallenge(nil)
                            return state
                        })
                        controller?.view.endEditing(true)
                        controller?.dismiss()
                        strongSelf.setupPassword()
                    }
                    strongSelf.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                }))
            })]), in: .window(.root))
        } else {
            self.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: self.presentationData.theme), title: nil, text: self.presentationData.strings.TwoStepAuth_RecoveryUnavailable, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
        }
    }
    
    private func setupPassword() {
        guard let verificationState = self.state.verificationState, case let .noChallenge(emailPattern) = verificationState else {
            return
        }
        var completionImpl: ((String, String, Bool) -> Void)?
        let state: CreatePasswordState
        if let emailPattern = emailPattern {
            state = .pendingVerification(emailPattern: emailPattern)
        } else {
            state = .setup(currentPassword: nil)
        }
        let controller = createPasswordController(account: self.account, context: .secureId, state: state, completion: { password, hint, hasRecoveryEmail in
            completionImpl?(password, hint, hasRecoveryEmail)
        }, updatePasswordEmailConfirmation: { [weak self] pattern in
            guard let strongSelf = self else {
                return
            }
            strongSelf.updateState(animated: false, { state in
                var state = state
                if let verificationState = state.verificationState, case .noChallenge = verificationState {
                    state.verificationState = .noChallenge(pattern?.1)
                }
                return state
            })
        })
        completionImpl = { [weak self, weak controller] password, hint, hasRecoveryEmail in
            guard let strongSelf = self else {
                controller?.dismiss()
                return
            }
            strongSelf.updateState(animated: false, { state in
                var state = state
                state.verificationState = .passwordChallenge(hint: hint, state: .none, hasRecoveryEmail: hasRecoveryEmail)
                return state
            })
            strongSelf.checkPassword(password: password, inBackground: true, completion: {
                controller?.view.endEditing(true)
                controller?.dismiss()
            })
        }
        self.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }
    
    @objc private func grantAccess() {
        switch self.state {
            case let .form(form):
                if case let .form(reqForm) = self.mode, let encryptedFormData = form.encryptedFormData, let formData = form.formData {
                    let values = parseRequestedFormFields(formData.requestedFields, values: formData.values, primaryLanguageByCountry: encryptedFormData.primaryLanguageByCountry).map({ $0.1 }).flatMap({ $0 })
                    
                    let _ = (grantSecureIdAccess(network: self.account.network, peerId: encryptedFormData.servicePeer.id, publicKey: reqForm.publicKey, scope: reqForm.scope, opaquePayload: reqForm.opaquePayload, opaqueNonce: reqForm.opaqueNonce, values: values, requestedFields: formData.requestedFields)
                    |> deliverOnMainQueue).start(completed: { [weak self] in
                        self?.dismiss()
                        self?.openUrl(secureIdCallbackUrl(with: reqForm.callbackUrl, peerId: reqForm.peerId, result: .success, parameters: [:]))
                    })
                }
            case .list:
                break
        }
    }
    
    @objc private func infoPressed() {
        self.present(standardTextAlertController(theme: AlertControllerTheme(presentationTheme: self.presentationData.theme), title: self.presentationData.strings.Passport_InfoTitle, text: self.presentationData.strings.Passport_InfoText.replacingOccurrences(of: "**", with: ""), actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {}), TextAlertAction(type: .genericAction, title: self.presentationData.strings.Passport_InfoLearnMore, action: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            openExternalUrl(account: strongSelf.account, url: strongSelf.presentationData.strings.Passport_InfoFAQ_URL, presentationData: strongSelf.presentationData, applicationContext: strongSelf.account.telegramApplicationContext, navigationController: strongSelf.navigationController as? NavigationController, dismissInput: {
                self?.view.endEditing(true)
            })
        })]), in: .window(.root))
    }
}
