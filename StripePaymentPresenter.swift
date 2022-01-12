//
//  StripePaymentPresenter.swift
//  ZYRLPad
//
//  Created by  Macbook on 28.01.2021.
//  Copyright © 2021 iOS Master. All rights reserved.
//

import Foundation
import StripeTerminal

protocol StripePaymentPresenterDelegate: AnyObject {
    func paymentIntentDidLoad(intent: PaymentIntent)
    func paymentIntentDidFaild()
    func paymentMethodDidCollect(intent: PaymentIntent)
    func paymentCollectFailed(error: Error)
    func paymentCollectCancelled()
    func paymentDidProcess(intent: PaymentIntent)
    func paymentProcessFailed(error: Error, status: PaymentIntentStatus?, errorIntent: PaymentIntent)
    func paymentDidCapture(intent: PaymentIntent)
    func paymentCaptureFailed()
    func startLoading()
    func stopLoading()
    func statusChanged(status: PaymentStatusView.Status)
}

class StripePaymentPresenter {
    
    private var captureAttempts: Int = 0
    private var maxCaptureAttempts: Int = 5
    weak var collectCancelable: Cancelable? = nil
    weak var viewController: StripePaymentPresenterDelegate?
    private var storage: LocalStorage
    private lazy var apiClient = APIClient(storage: storage)
    var isPaymentCanceled = false
    
    init(storage: LocalStorage, vc: StripePaymentPresenterDelegate?) {
        self.viewController = vc
        self.storage = storage
    }
    
    func retrievePaymentIntent(paymentType: PaymentType, settings: PaymentSettings) {
        
        isPaymentCanceled = false
        viewController?.startLoading()
        viewController?.statusChanged(status: .changeStatus("Connecting to server..."))
        
        apiClient.requestPaymentIntent(paymentType: paymentType, orderUUID: settings.orderUUID) {[weak self] (clientSecret) in
            
            DispatchQueue.main.async {
                
                guard let secret = clientSecret else {
                        self?.viewController?.stopLoading()
                        self?.viewController?.statusChanged(status: .failed("Failed to connect to server. Please exit and try again."))
                    self?.viewController?.paymentIntentDidFaild()
                    return
                }
                
                self?.retrievePaymentIntentFromTerminal(secret: secret)
            }
        }
    }
    
    func retrievePaymentIntentForEvent(settings: PaymentSettings) {
        
        guard let uuid = settings.event?.uuid else {
            self.viewController?.paymentIntentDidFaild()
            return
        }
        
        isPaymentCanceled = false
        viewController?.startLoading()
        viewController?.statusChanged(status: .changeStatus("Connecting to server..."))
        
        apiClient.fetchPaymentIntentForCateringEvent(uuid: uuid) {[weak self] (result) in
            
            switch result {
            case .success(let secret):
                self?.retrievePaymentIntentFromTerminal(secret: secret)
            case .failure:
                DispatchQueue.main.async {
                    self?.viewController?.stopLoading()
                    self?.viewController?.statusChanged(status: .failed("Failed to connect to server. Please exit and try again."))
                    self?.viewController?.paymentIntentDidFaild()
                }
            }
        }
    }
    
    private func retrievePaymentIntentFromTerminal(secret: String) {
        Terminal.shared.retrievePaymentIntent(clientSecret: secret, completion: {[weak self] (paymentIntent, error) in
            
            DispatchQueue.main.async {
            
                self?.viewController?.stopLoading()
                
                if let error = error {
                    self?.viewController?.paymentIntentDidFaild()
                    self?.viewController?.statusChanged(status: .failed("Please exit and try again."))
                    self?.viewController?.statusChanged(status: .description(error.localizedDescription))
                    
                } else if let paymentIntent = paymentIntent {
                    self?.viewController?.paymentIntentDidLoad(intent: paymentIntent)
                }
            }
        })
    }
    
    func cancelCollectPayments() {
        isPaymentCanceled = true
        collectCancelable?.cancel({ (error) in
            if let error = error {
                print("error cancelling payment: \(error)")
            }
        })
    }
    
    func collectPaymentMethod(intent: PaymentIntent) {
        
        viewController?.startLoading()
        viewController?.statusChanged(status: .changeStatus("Please leave card inserted until processing ends"))
        
        collectCancelable = Terminal.shared.collectPaymentMethod(intent) { [weak self] collectResult, collectError in
            
            DispatchQueue.main.async {
                self?.viewController?.stopLoading()
                self?.collectCancelable = nil
                
                if let error = collectError as NSError?, error.code == 2020 {
                    self?.viewController?.paymentCollectCancelled()
                    return
                }
                
                if let error = collectError {
                    self?.viewController?.statusChanged(status: .failed("The payment has failed, please exit and try again"))
                    self?.viewController?.statusChanged(status: .description(error.localizedDescription))
                    self?.viewController?.paymentCollectFailed(error: error)
                    
                } else if let paymentIntent = collectResult {
                    self?.viewController?.paymentMethodDidCollect(intent: paymentIntent)
                }
            }
        }
    }
    
    func processPayment(intent: PaymentIntent) {
        
        viewController?.startLoading()
        viewController?.statusChanged(status: .changeStatus("Processing Payment..."))

        Terminal.shared.processPayment(intent) { [weak self] processResult, processError in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
            
                self.viewController?.stopLoading()
                
                if let error = processError {
                    print("processPayment failed: \(error)")
                        
                        var errorMessage = "Your payment could not be processed. Please try another card."
                        print("PaymentIntent: \(intent.status.rawValue)")
                        print("Error PaymentIntent: \(String(describing: error.paymentIntent?.status.rawValue))")
                        
                        if let status = error.paymentIntent?.status {
                        
                            if error.paymentIntent?.status == PaymentIntentStatus.requiresConfirmation {
                                errorMessage = "Failed to process your payment. Please try again."
                                if let updatedIntent = error.paymentIntent {
                                    self.viewController?.paymentProcessFailed(error: error, status: status, errorIntent: updatedIntent)
                                }
                            } else if error.paymentIntent?.status == PaymentIntentStatus.requiresPaymentMethod {
                                errorMessage = "Your payment was declined. Please try another card."
                                if let updatedIntent = error.paymentIntent {
                                    self.viewController?.paymentProcessFailed(error: error, status: status, errorIntent: updatedIntent)
                                }
                            } else {
                                errorMessage = "We were unable to process your payment. Please exit and try again."
                            }
                    
                        } else {
                            errorMessage = "Uh oh, something went wrong. Please exit and try again."
                            self.viewController?.paymentProcessFailed(error: error, status: nil, errorIntent: intent)
                        }
                        
                    self.viewController?.statusChanged(status: .failed(errorMessage))
                    
                } else if let paymentIntent = processResult {
                    print("processPayment succeeded")
                    // Notify your backend to capture the PaymentIntent
                    self.viewController?.paymentDidProcess(intent: paymentIntent)
                }
            }
        }
    }
    
    func capturePayment(intent: PaymentIntent) {
        
        viewController?.startLoading()
        
        captureAttempts += 1

        if captureAttempts <= maxCaptureAttempts {
            apiClient.capturePaymentIntent(intent.stripeId) { [weak self] (captureError) in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.viewController?.stopLoading()
                    
                    if captureError != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.capturePayment(intent: intent)
                        }
                    } else {
                        self.viewController?.paymentDidCapture(intent: intent)
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.viewController?.stopLoading()
                self.viewController?.statusChanged(status: .failed("Transaction incomplete. Please check the network, exit and try again."))
                self.viewController?.paymentCaptureFailed()
            }
        }
    }
}
