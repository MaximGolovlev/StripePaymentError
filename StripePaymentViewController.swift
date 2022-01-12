//
//  StripePaymentViewController.swift
//  ZYRLPad
//
//  Created by Christopher Sukhram on 8/7/19.
//  Copyright © 2019 iOS Master. All rights reserved.
//

import UIKit
import StripeTerminal
import DeviceKit
import FirebaseCrashlytics

struct PaymentSettings {
    var total: Float
    var restaurantID: Int
    var restaurantName: String
    var createdAt: String
    var subtotal: Float
    var discounts: Float
    var tipAmount: Float
    var serviceFee: Float
    var taxAmount: Float
    var orderUUID: String
    var orderNumber: String?
    var isPayLaterEnabled: Bool
    var items = [OrderItem]()
    var event: CateringEvent? = nil
    var paymentStatus: PaymentStatus?
    
    init(cart: ShoppingCart, orderUUID: String, orderNumber: String, location: Restaurant, isPayLaterEnabled: Bool) {
        self.total = cart.total
        self.restaurantID = cart.restaurant.rstId
        self.restaurantName = location.rstName
        self.subtotal = cart.subtotal
        self.discounts = cart.totalDiscountAmount
        self.tipAmount = cart.tipAmount
        self.taxAmount = cart.taxAmount
        self.serviceFee = cart.serviceFee
        self.orderUUID = orderUUID
        self.orderNumber = orderNumber
        self.isPayLaterEnabled = isPayLaterEnabled
        self.createdAt = Date().toString(dateFormat: "M/dd/yyyy h:mm a")
        self.paymentStatus = nil
    }
    
    init(pastOrder: PastOrder, location: Restaurant, isPayLaterEnabled: Bool) {
        self.total = pastOrder.total
        self.restaurantID = location.rstId
        self.restaurantName = location.rstName
        self.subtotal = pastOrder.subtotal
        self.discounts = pastOrder.discount
        self.tipAmount = pastOrder.tips
        self.serviceFee = pastOrder.fee
        self.taxAmount = 0
        self.orderUUID = pastOrder.uuid
        self.orderNumber = pastOrder.orderNumber
        self.isPayLaterEnabled = isPayLaterEnabled
        self.createdAt = pastOrder.createdAtString
        self.items = pastOrder.items
        self.paymentStatus = pastOrder.paymentStatus
    }
    
    init(event: CateringEvent) {
        self.total = 0
        self.restaurantID = 0
        self.restaurantName = ""
        self.subtotal = 0
        self.discounts = 0
        self.tipAmount = 0
        self.taxAmount = 0
        self.serviceFee = 0
        self.orderUUID = ""
        self.orderNumber = ""
        self.isPayLaterEnabled = false
        self.createdAt = ""
        self.items = []
        self.event = event
        self.paymentStatus = nil
    }
}

protocol StripePaymentDelegate: AnyObject {
    func stripePayment(stripePaymentVC: StripePaymentViewController, finishedPaymentFor paymentIntent: PaymentIntent)
    func stripePayment(stripePaymentVC: StripePaymentViewController, requestToPayCash: Bool, orderUUID: String)
    func stripePayment(stripePaymentVC: StripePaymentViewController, requestPayLater: Bool, orderUUID: String)
    func paymentMethodDidCollect(stripePaymentVC: StripePaymentViewController, intent: PaymentIntent, completion: (() -> Void)?)
    func closeTapped()
    func paymentSucceed()
}

struct StripePaymentViewControllerAppearance {
    struct paymentMethodsView {
        static let top: CGFloat = Device.isIPadPro ? 186 : 170
    }
}

class StripePaymentViewController: BaseViewController {
    
    typealias Appearance = StripePaymentViewControllerAppearance
    
    lazy var cashAlert: UIAlertController = {
        let alert = UIAlertController(title: "Are you sure?", message: "To pay with cash you will need to proceed to the counter after completing your order", preferredStyle: .alert)
        
        let confirm = UIAlertAction(title: "Pay with Cash", style: .default) { [weak self] (action) in
            self?.requestPayForCash()
        }
        
        let cancel = UIAlertAction(title: "Cancel", style: .destructive) { (action) in
            alert.dismiss(animated: true)
        }
        
        alert.addAction(cancel)
        alert.addAction(confirm)
        return alert
    }()
    
    lazy var closeButton: UIButton = {
        $0.tintColor = UIColor.appBlack
        $0.setImage(#imageLiteral(resourceName: "Close_Button"), for: .normal)
        $0.addTarget(self, action: #selector(exitDidTap), for: .touchUpInside)
        return $0
    }(UIButton(type: .system))
    
    var cashPaymentView: CashPaymentView!
    
    let readerStatusView: ReaderStatusView = {
        $0.isHidden = true
        return $0
    }(ReaderStatusView())
    
    lazy var paymentMethodsView: PaymentMethodsView = {
        $0.isHidden = true
        return $0
    }(PaymentMethodsView(amount: visualTotal ??
                            storage.shoppingCart?.total ??
                            paymentSettings.event?.totalSalesFloat ??
                            paymentSettings.total,
                         isPayLaterEnabled: paymentSettings.isPayLaterEnabled,
                         isCashAccepted: isCashAccepted,
                         storage: storage))
    
    let paymentStatusView: PaymentStatusView = {
        $0.isHidden = true
        return $0
    }(PaymentStatusView())
    
    let poweredByView = PoweredByView()
    var stripeUpdateView: StripeUpdateView?
    var isPresentingReconnectFlow = false
    var hasPresentedReconnectFlow = false
    var isProcessing: Bool { Terminal.shared.paymentStatus == .processing }
    var isCashAccepted: Bool
    var isDiscoveringReaders: Bool { stripeManager.isDiscoveringReaders }
    var orderUUID: String { paymentSettings.orderUUID }
    
    var location: Restaurant
    var paymentSettings: PaymentSettings
    weak var delegate: StripePaymentDelegate?
    lazy var presenter = StripePaymentPresenter(storage: storage, vc: self)
    lazy var stripeManager = StripeManager(storage: storage)
    private var visualTotal: Float?
    
    init(location: Restaurant, storage: LocalStorage, visualTotal: Float?, paymentSettings: PaymentSettings) {
        self.location = location
        self.paymentSettings = paymentSettings
        self.isCashAccepted = location.isCashAccepted
        self.visualTotal = visualTotal
        super.init(storage: storage)
        
        cashPaymentView = CashPaymentView(amount: storage.shoppingCart?.total)
        cashPaymentView.isHidden = true
    }
    
    init(location: Restaurant, storage: LocalStorage, paymentSettings: PaymentSettings, visualAmount: Float) {
        self.location = location
        self.paymentSettings = paymentSettings
        self.isCashAccepted = location.isCashAccepted
        self.visualTotal = visualAmount
        
        super.init(storage: storage)
        
        cashPaymentView = CashPaymentView(amount: visualAmount)
        cashPaymentView.isHidden = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = #colorLiteral(red: 0.9568627451, green: 0.9568627451, blue: 0.9568627451, alpha: 1)

        configureViews()
        handleActions()
    }
    
    func configureViews() {
        
        view.addSubview(closeButton)
        closeButton.anchor(view.topAnchor, left: view.leftAnchor, topConstant: 32, leftConstant: 32, widthConstant: 75, heightConstant: 75)
        
        view.addSubview(cashPaymentView)
        cashPaymentView.anchor(view.topAnchor, left: view.leftAnchor, right: view.rightAnchor, topConstant: 208, leftConstant: 100, rightConstant: 100)
        
        view.addSubview(readerStatusView)
        readerStatusView.anchor(view.topAnchor, left: view.leftAnchor, right: view.rightAnchor, topConstant: 208, leftConstant: 100, rightConstant: 100)
        
        view.addSubview(paymentMethodsView)
        paymentMethodsView.anchor(view.topAnchor, topConstant: Appearance.paymentMethodsView.top)
        paymentMethodsView.anchorCenterXToSuperview()
        
        view.addSubview(paymentStatusView)
        paymentStatusView.anchor(view.topAnchor, left: view.leftAnchor, right: view.rightAnchor, topConstant: 208, leftConstant: 100, rightConstant: 100)
        
        view.addSubview(poweredByView)
        poweredByView.anchor(bottom: view.bottomAnchor)
        poweredByView.anchorCenterXToSuperview()

    }
    
    func handleActions() {
        readerStatusView.reconnectHandler = { [weak self] in
            guard self?.isDiscoveringReaders == false && self?.stripeManager.connectedReader == nil else { return }
            self?.presentReconnectFlow()
        }
        
        cashPaymentView.cashPaymentHandler = { [weak self] in
            guard self?.isProcessing == false else { return }
            self?.payWithCash()
        }
        
        paymentMethodsView.cashPaymentHandler = { [weak self] in
            guard self?.isProcessing == false else { return }
            self?.payWithCash()
        }
        
        paymentMethodsView.payLaterHandler = { [weak self] in
            guard self?.isProcessing == false else { return }
            self?.payLater()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        self.updateView(isFirstTime: true)
    }
    
    func updateView(isFirstTime: Bool) {
        
        if location.isCashOnly {
            cashPaymentView.showAnimated()
            
        } else {
            cashPaymentView.hideAnimated()
            
            if Terminal.shared.connectedReader == nil {
                if !stripeManager.isDiscoveringReaders {
                    stripeManager.stripeManagerDelegate = self
                    stripeManager.requestDelayNotication(seconds: 10)
                    stripeManager.performDiscoverySafely(selectedLocation: location)
                    
                    readerStatusView.showAnimated()
                }
            } else {
                readerStatusView.hideAnimated()
                if isFirstTime { paymentMethodsView.showAnimated() }
                createPaymentIntent()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        presenter.cancelCollectPayments()
        stripeManager.cancelDiscovery { (result) in }
    }
    
    func payWithCash() {
        if storage.shoppingSessionInfo.appMode == .pos {
            self.requestPayForCash()
        } else {
            self.present(cashAlert, animated: true) {}
        }
    }
    
    func payLater() {
        requestPayLater()
    }
    
    private func requestPayForCash() {
        guard isProcessing == false else { return }
        presenter.cancelCollectPayments()
        delegate?.stripePayment(stripePaymentVC: self, requestToPayCash: true, orderUUID: orderUUID)
    }
    
    private func requestPayLater() {
        guard isProcessing == false else { return }
        presenter.cancelCollectPayments()
        
        let vc = PayLaterAlertController()
        vc.modalPresentationStyle = .overFullScreen
        vc.continueHandler = { [weak self, weak vc] in
            vc?.dismiss(animated: true) { [weak self] in
                guard let self = self else { return }
                self.delegate?.stripePayment(stripePaymentVC: self, requestPayLater: true, orderUUID: self.orderUUID)
            }
        }
        vc.cancelHandler = { [weak self, weak vc] in
            vc?.dismiss(animated: true) { [weak self] in
                self?.createPaymentIntent()
            }
        }
        present(vc, animated: true, completion: nil)
    }
    
    @objc func exitDidTap() {
        presenter.cancelCollectPayments()
        delegate?.closeTapped()
        dismiss(animated: true)
    }
    
    func createPaymentIntent() {
        if paymentSettings.event != nil {
            presenter.retrievePaymentIntentForEvent(settings: paymentSettings)
        } else {
            presenter.retrievePaymentIntent(paymentType: .regular, settings: paymentSettings)
        }
    }

    private func presentReconnectFlow() {
        let reconnectFlow = ReconnectFlowController(stripeManager: stripeManager)
        reconnectFlow.modalPresentationStyle = .overCurrentContext
        reconnectFlow.delegate = self
        self.present(reconnectFlow, animated: true) {
            self.isPresentingReconnectFlow = true
             self.hasPresentedReconnectFlow = true
        }
    }
    
    func hidePaymentViews() {
        paymentMethodsView.hideAnimated()
        paymentStatusView.hideAnimated()
    }
    
}

extension StripePaymentViewController: StripePaymentPresenterDelegate {

    func paymentIntentDidLoad(intent: PaymentIntent) {
        guard !presenter.isPaymentCanceled else { return }
        presenter.collectPaymentMethod(intent: intent)
    }
    
    func paymentIntentDidFaild() {
        paymentMethodsView.hideAnimated()
        paymentStatusView.showAnimated()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: {
            self.updateView(isFirstTime: false)
        })
        Crashlytics.crashlytics().record(exceptionModel: ExceptionModel(name: "paymentIntentDidFaild", reason: "\(location.rstName)"))
    }
    
    func paymentMethodDidCollect(intent: PaymentIntent) {
        paymentMethodsView.hideAnimated()
        paymentStatusView.showAnimated()
        closeButton.isEnabled = false
        delegate?.paymentMethodDidCollect(stripePaymentVC: self, intent: intent) { [weak self] in
            self?.presenter.processPayment(intent: intent)
        }
    }
    
    func paymentCollectFailed(error: Error) {
        paymentMethodsView.hideAnimated()
        paymentStatusView.showAnimated()
        Crashlytics.crashlytics().record(error: error)
    }
    
    func paymentCollectCancelled() {
        print("aaaa")
    }
    
    func paymentDidProcess(intent: PaymentIntent) {
        presenter.capturePayment(intent: intent)
    }
    
    func paymentProcessFailed(error: Error, status: PaymentIntentStatus?, errorIntent: PaymentIntent) {
        
        self.closeButton.isEnabled = true
        
        Crashlytics.crashlytics().record(error: error)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: { [weak self] in
            guard let self = self else { return }
            switch status {
            case .requiresConfirmation:
                self.presenter.processPayment(intent: errorIntent)
            case .requiresPaymentMethod:
                self.presenter.collectPaymentMethod(intent: errorIntent)
            default:
                self.presenter.processPayment(intent: errorIntent)
            }
        })
    }
    
    func paymentDidCapture(intent: PaymentIntent) {
        paymentStatusView.update(status: .success("Payment Processed"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: { [weak self] in
            guard let self = self else { return }
            self.paymentStatusView.hideAnimated()
            self.delegate?.stripePayment(stripePaymentVC: self, finishedPaymentFor: intent)
        })
    }
    
    func paymentCaptureFailed() {
         self.closeButton.isEnabled = true
    }
    
    func startLoading() {

    }
    
    func stopLoading() {

    }
    
    func statusChanged(status: PaymentStatusView.Status) {
        paymentStatusView.update(status: status)
    }
    
}

// Stripe processing

// MARK: - StripeManagerDelegate

extension StripePaymentViewController: StripeManagerDelegate {
    
    func stripeManager(stripeManager: StripeManager, receivedError error: Error) {
        readerStatusView.update(status: .failed(error.localizedDescription))
    }
    
    func stripeManager(stripeManager: StripeManager, connectedTo reader: Reader) {
        storage.readerSessionInfo.serial = reader.serialNumber
        
        readerStatusView.update(status: .success("Reader connected successfully!"))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: {
            self.updateView(isFirstTime: true)
        })
    }
    
    func stripeManager(stripeManager: StripeManager, errorConnectingToReader: Error) {
        Utils.showAlert(msg: errorConnectingToReader.localizedDescription, ctrl: self, completion: nil)
    }
    
    func stripeManager(stripeManager: StripeManager, discovered configuredReader: Reader) {
        print("should be connected")
    }
    
    func stripeManager(stripeManager: StripeManager, delayNotificationFor delayInSeconds: Int, totalDiscoveryTime: Int) {
            print("RECEIVED DELAY NOTIFICATION for \(delayInSeconds) seconds")
            if !isPresentingReconnectFlow {
                var event = "Connectfion Delay"
                event += hasPresentedReconnectFlow == true ? " Again": ""
                stripeManager.sendTroubleShootingEmail(location: location, event: event, from: "StripePayment")
                presentReconnectFlow()
            }
    }
    
    func stripeManager(stripeManager: StripeManager, timeUpdate discoveryTimeInSeconds: Int) {
        print("FROM PAYMENT")

    }
    
    func stripeManager(stripeManager: StripeManager, discovered readers: [Reader]) {
        
        DispatchQueue.main.async { [weak self] in
            
            guard readers.count > 1 else {
                if let reader = readers.first {
                    self?.stripeManager.connectReader(reader)
                }
                return
            }
            
            let readerNames = readers.compactMap({ $0.label })
            self?.showMultiselectAlert(options: readerNames) { index in
                let reader = readers[index]
                self?.stripeManager.connectReader(reader)
            }
        }
    }
    
    func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {
        paymentMethodsView.update(inputOptions: inputOptions)
    }
    
    func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        
        guard presenter.collectCancelable != nil else { return }
        
        cashAlert.dismiss(animated: true, completion: nil)
        paymentMethodsView.hideAnimated()
        paymentStatusView.showAnimated()
        
        var message = ""
        
        switch displayMessage {
        case .insertCard:
            message = "Insert card"
        case .insertOrSwipeCard:
            message = "Insert or swipe card"
        case .multipleContactlessCardsDetected:
            message = "Multiple cards detected"
        case .removeCard:
            message = "Please remove card"
        case .retryCard:
            message = "Retry card"
        case .swipeCard:
            message = "Swipe card"
        case .tryAnotherCard:
            message = "Try another card"
        case .tryAnotherReadMethod:
            message = "Try another read method"
        default:
            message = "Unknown reader status"
        }
        
        paymentStatusView.update(status: .description(message))
    }
    
    func terminal(_ terminal: Terminal, didReportUnexpectedReaderDisconnect reader: Reader) {
        paymentStatusView.update(status: .failed("The Stripe Reader has disconnected. Please exit and try again."))
    }
}

extension StripePaymentViewController: DiscoveryDelegate {
    // MARK: DiscoveryDelegate
    
    func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        // Only connect if we aren't currently connected.
        guard terminal.connectionStatus == .notConnected else { return }
        
        let serialNumber = storage.readerSessionInfo.serial
        for reader in readers {
            if reader.serialNumber == serialNumber {
                print("WE FOUND THE SERIAL NUMBER OF THE CONNECTED DEVICE")
                connectReader(reader: reader)
            }
        }
    }
    
    private func connectReader(reader: Reader) {
        
        stripeManager.connectReader(reader, selectedLocation: nil) { [weak self] reader, error in
            if let reader = reader {
                print("Successfully connected to reader: \(reader)")
                self?.storage.readerSessionInfo.serial = reader.serialNumber
                LocalStorage.stripeReaderSerial = reader.serialNumber
            }
            else if let error = error {
                print("connectReader failed: \(error)")
            }
        }
    }
}

// MARK: - ReconnectFlow Delegate

extension StripePaymentViewController: ReconnectFlowDelegate {
    
    func didClose() {
        self.stripeManager.stripeManagerDelegate = self
    }
    
    func reconnectFlow(reconnectFlowCompleted reconnectFlowVC: ReconnectFlowController, success: Bool, readerSerial: String?) {
        
        if let serial = readerSerial {
            storage.readerSessionInfo.serial = serial
        }
        
        reconnectFlowVC.dismiss(animated: true) {
            self.isPresentingReconnectFlow = false
        }
        self.updateView(isFirstTime: true)
    }
}


