//
//  NFCCardReaderBase.swift
//  NFCCardReader
//
//  Created by kehinde omotoso on 13/03/2025.
//

import Foundation
import CoreNFC

@available(iOS 13.0, *)
class NFCCardReaderBase: NSObject, NFCTagReaderSessionDelegate {
    // MARK: - EMV Constants
    private enum EMVTags {
        static let FCI_TEMPLATE = "6F"
        static let FCI_PROPRIETARY = "A5"
        static let FCI_ISSUER_DISCRETIONARY = "BF0C"
        static let APPLICATION_DIRECTORY = "61"
        static let AID = "4F"
        static let APPLICATION_LABEL = "50"
        static let TRACK2 = "57"
        static let PAN = "5A"
        static let CARDHOLDER_NAME = "5F20"
        static let EXPIRY_DATE = "5F24"
        static let RESPONSE_MESSAGE_TEMPLATE = "77"
        static let RECORD_TEMPLATE = "70"
        static let APPLICATION_TEMPLATE = "61"
        static let AFL = "94"
        static let GPO_RESPONSE_TEMPLATE = "80"
    }
    
    // MARK: - Card Data Structure
    struct CardData {
        var isSuccess: Bool = false
        var error: String?
        var pan: String?
        var track2: String?
        var expiryDate: String?
        var cardholderName: String?
        var applicationLabel: String?
        var aid: String?
    }
    
    private var session: NFCTagReaderSession?
    private var completionHandler: ((Result<CardData, Error>) -> Void)?
    private var isSessionActive = false
    private var isProcessing = false
    
    deinit {
        invalidateSession()
    }
    
    private func invalidateSession() {
        session?.invalidate()
        session = nil
        isSessionActive = false
    }
    
    // MARK: - Public Interface
    func startScanning(completion: @escaping (Result<CardData, Error>) -> Void) {
        //        guard NFCTagReaderSession.readingAvailable else {
        //            DispatchQueue.main.async {
        //                completion(.failure(NFCError.notSupported))
        //            }
        //            return
        //        }
        //
        //        invalidateSession()
        //
        //        completionHandler = completion
        //        session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self)
        //        session?.alertMessage = "Hold your iPhone near the payment card"
        //
        //        DispatchQueue.main.async { [weak self] in
        //            self?.session?.begin()
        //        }
        
        DispatchQueue.main.async {
            guard NFCTagReaderSession.readingAvailable else {
                completion(.failure(NFCError.notSupported))
                return
            }
            
            // Clean up any existing session
            self.session?.invalidate()
            self.session = nil
            self.isProcessing = false
            
            // Store completion handler
            self.completionHandler = completion
            
            // Create and start new session
            self.session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self)
            self.session?.alertMessage = "Hold your iPhone near the payment card"
            self.session?.begin()
        }
    }
    
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        isSessionActive = true
    }
    
    //    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    //        isSessionActive = false
    //
    //        // Don't report user-cancelled errors
    //        if let nfcError = error as? NFCReaderError,
    //           nfcError.code == .readerSessionInvalidationErrorUserCanceled {
    //            return
    //        }
    //
    //        DispatchQueue.main.async { [weak self] in
    //            self?.completionHandler?(.failure(error))
    //            self?.session = nil
    //        }
    //    }
    
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard !isProcessing else { return }
        
        if let nfcError = error as? NFCReaderError,
           nfcError.code == .readerSessionInvalidationErrorUserCanceled {
            completeSession(with: .failure(NFCError.userCancelled))
        } else {
            completeSession(with: .failure(error))
        }
    }
    
    //    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    //        guard let firstTag = tags.first else {
    //            session.invalidate(errorMessage: "No tag detected")
    //            return
    //        }
    //
    //        guard case .iso7816(let tag) = firstTag else {
    //            session.invalidate(errorMessage: "Invalid card type")
    //            return
    //        }
    //
    //        // Connect to the card
    //        session.connect(to: firstTag) { [weak self] error in
    //            guard let self = self else { return }
    //
    //            if let error = error {
    //                session.invalidate(errorMessage: "Connection error: \(error.localizedDescription)")
    //                return
    //            }
    //
    //            // Start reading the card with proper error handling
    //            self.processCard(tag, session: session)
    //        }
    //    }
    
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard !isProcessing else { return }
        isProcessing = true
        
        // Ensure we have a valid tag
        guard let firstTag = tags.first,
              case .iso7816(let tag) = firstTag else {
            session.invalidate(errorMessage: "Unsupported card type")
            return
        }
        
        // Connect to the detected tag
        session.connect(to: firstTag) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.handleError(error, session: session)
                return
            }
            
            self.processCard(tag, session: session)
        }
    }
    
    private func processCard(_ tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        guard isSessionActive else { return }
        
        // PPSE command with error handling
        let ppseCommand = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xA4,
            p1Parameter: 0x04,
            p2Parameter: 0x00,
            data: "2PAY.SYS.DDF01".data(using: .ascii) ?? Data(),
            expectedResponseLength: -1
        )
        
        tag.sendCommand(apdu: ppseCommand) { [weak self] ppseResponse, sw1, sw2, error in
            guard let self = self, self.isSessionActive else { return }
            
            if let error = error {
                session.invalidate(errorMessage: "PPSE error: \(error.localizedDescription)")
                return
            }
            
            // Check for successful response
            guard sw1 == 0x90, sw2 == 0x00 else {
                session.invalidate(errorMessage: "Invalid PPSE response")
                return
            }
            
            guard let aid = self.findFirstAID(in: ppseResponse) else {
                session.invalidate(errorMessage: "No payment AID found")
                return
            }
            
            // Continue with application selection
            self.selectApplication(aid, tag: tag, session: session)
        }
    }
    
    private func selectApplication(_ aid: Data, tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        guard isSessionActive else { return }
        
        let selectCommand = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xA4,
            p1Parameter: 0x04,
            p2Parameter: 0x00,
            data: aid,
            expectedResponseLength: -1
        )
        
        tag.sendCommand(apdu: selectCommand) { [weak self] response, sw1, sw2, error in
            guard let self = self, self.isSessionActive else { return }
            
            if let error = error {
                session.invalidate(errorMessage: "Application selection error: \(error.localizedDescription)")
                return
            }
            
            guard sw1 == 0x90, sw2 == 0x00 else {
                session.invalidate(errorMessage: "Invalid application selection response")
                return
            }
            
            self.getProcessingOptions(tag: tag, session: session)
        }
    }
    
    private func getProcessingOptions(tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        let gpoCommand = NFCISO7816APDU(
            instructionClass: 0x80,
            instructionCode: 0xA8,
            p1Parameter: 0x00,
            p2Parameter: 0x00,
            data: Data([0x83, 0x00]),
            expectedResponseLength: -1
        )
        
        tag.sendCommand(apdu: gpoCommand) { [weak self] response, sw1, sw2, error in
            guard let self = self else { return }
            
            if let error = error {
                session.invalidate(errorMessage: "GPO error: \(error.localizedDescription)")
                return
            }
            
            // Parse AFL and read records
            if let afl = self.parseAFL(from: response) {
                self.readRecords(afl: afl, tag: tag, session: session)
            } else {
                self.readCommonRecords(tag: tag, session: session)
            }
        }
    }
    
    private func findFirstAID(in data: Data) -> Data? {
        // Implement TLV parsing to find AID (tag 4F)
        // This is a simplified version - you'll need proper TLV parsing
        let aidTag: UInt8 = 0x4F
        var index = data.startIndex
        
        while index < data.endIndex {
            if data[index] == aidTag,
               index + 1 < data.endIndex {
                let length = Int(data[index + 1])
                if index + 2 + length <= data.endIndex {
                    return data.subdata(in: (index + 2)..<(index + 2 + length))
                }
            }
            index += 1
        }
        return nil
    }
    
    private func parseAFL(from response: Data) -> [UInt8]? {
        // Parse Application File Locator from GPO response
        // This is a simplified version - you'll need proper TLV parsing
        let aflTag: UInt8 = 0x94
        var index = response.startIndex
        
        while index < response.endIndex {
            if response[index] == aflTag,
               index + 1 < response.endIndex {
                let length = Int(response[index + 1])
                if index + 2 + length <= response.endIndex {
                    return Array(response.subdata(in: (index + 2)..<(index + 2 + length)))
                }
            }
            index += 1
        }
        return nil
    }
    
    private func readRecords(afl: [UInt8], tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        var cardData = CardData(isSuccess: true)
        var remainingRecords = afl.count / 4
        
        for i in stride(from: 0, to: afl.count, by: 4) {
            guard i + 3 < afl.count else { break }
            
            let sfi = afl[i]
            let firstRecord = afl[i + 1]
            let lastRecord = afl[i + 2]
            
            for record in firstRecord...lastRecord {
                let recordCommand = NFCISO7816APDU(
                    instructionClass: 0x00,
                    instructionCode: 0xB2,
                    p1Parameter: record,
                    p2Parameter: (sfi << 3) | 4,
                    data: Data(), // Add empty Data
                    expectedResponseLength: -1
                )
                
                tag.sendCommand(apdu: recordCommand) { [weak self] response, sw1, sw2, error in
                    guard let self = self else { return }
                    
                    if error != nil {
                        remainingRecords -= 1
                        if remainingRecords == 0 {
                            self.completeCardReading(cardData: cardData, session: session)
                        }
                        return
                    }
                    
                    // Parse record data and update cardData
                    self.parseRecordData(response, into: &cardData)
                    
                    remainingRecords -= 1
                    if remainingRecords == 0 {
                        self.completeCardReading(cardData: cardData, session: session)
                    }
                }
            }
        }
    }
    
    private func completeSession(with result: Result<CardData, Error>) {
        DispatchQueue.main.async {
            self.completionHandler?(result)
            self.session?.invalidate()
            self.session = nil
            self.isProcessing = false
            self.completionHandler = nil
        }
    }
    
    private func handleError(_ error: Error, session: NFCTagReaderSession) {
        DispatchQueue.main.async {
            if let nfcError = error as? NFCReaderError,
               nfcError.code == .readerSessionInvalidationErrorUserCanceled {
                // Don't show error for user cancellation
                session.invalidate()
            } else {
                session.invalidate(errorMessage: error.localizedDescription)
            }
            self.isProcessing = false
        }
    }
    
    private func parseRecordData(_ data: Data, into cardData: inout CardData) {
        // Parse PAN
        if let pan = findTag(EMVTags.PAN, in: data) {
            cardData.pan = pan.hexString
        }
        
        // Parse Track 2
        if let track2 = findTag(EMVTags.TRACK2, in: data) {
            cardData.track2 = track2.hexString
            if cardData.pan == nil {
                cardData.pan = extractPANFromTrack2(track2)
            }
        }
        
        // Parse Expiry Date
        if let expiryDate = findTag(EMVTags.EXPIRY_DATE, in: data) {
            cardData.expiryDate = formatExpiryDate(expiryDate)
        }
        
        // Parse Cardholder Name
        if let cardholderName = findTag(EMVTags.CARDHOLDER_NAME, in: data) {
            cardData.cardholderName = String(data: cardholderName, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        }
        
        // Parse Application Label
        if let applicationLabel = findTag(EMVTags.APPLICATION_LABEL, in: data) {
            cardData.applicationLabel = String(data: applicationLabel, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        }
    }
    
    private func completeCardReading(cardData: CardData, session: NFCTagReaderSession) {
        completionHandler?(.success(cardData))
        session.invalidate()
    }
    
    // Helper function to find TLV tag in data
    private func findTag(_ tag: String, in data: Data) -> Data? {
        // Implement TLV parsing to find specific tag
        // This is a simplified version - you'll need proper TLV parsing
        guard let tagBytes = tag.hexadecimalData else { return nil }
        var index = data.startIndex
        
        while index < data.endIndex {
            if data[index] == tagBytes[0],
               index + 1 < data.endIndex {
                let length = Int(data[index + 1])
                if index + 2 + length <= data.endIndex {
                    return data.subdata(in: (index + 2)..<(index + 2 + length))
                }
            }
            index += 1
        }
        return nil
    }
    
    private func readCommonRecords(tag: NFCISO7816Tag, session: NFCTagReaderSession) {
        var cardData = CardData(isSuccess: true)
        let recordsToRead = 20 // Maximum number of common records to try
        var completedRecords = 0
        
        // Try reading common record locations
        for sfi in 1...10 {
            for record in 1...2 { // Try first two records in each file
                let recordCommand = NFCISO7816APDU(
                    instructionClass: 0x00,
                    instructionCode: 0xB2,
                    p1Parameter: UInt8(record),
                    p2Parameter: UInt8((sfi << 3) | 4), data: Data(),
                    expectedResponseLength: -1
                )
                
                tag.sendCommand(apdu: recordCommand) { [weak self] response, sw1, sw2, error in
                    guard let self = self else { return }
                    
                    completedRecords += 1
                    
                    if error == nil && sw1 == 0x90 && sw2 == 0x00 {
                        // Valid response received
                        self.parseRecordData(response, into: &cardData)
                    }
                    
                    // Check if we've completed all record attempts
                    if completedRecords >= recordsToRead {
                        // If we found any useful data, consider it a success
                        if cardData.pan != nil || cardData.track2 != nil {
                            self.completeCardReading(cardData: cardData, session: session)
                        } else {
                            session.invalidate(errorMessage: "Could not read card data")
                            self.completionHandler?(.failure(NFCError.readError))
                        }
                    }
                }
            }
        }
    }
    
    // Also add these helper methods if they're not already present
    
    private func extractPANFromTrack2(_ track2Data: Data) -> String? {
        let track2String = track2Data.hexString
        if let separatorIndex = track2String.firstIndex(of: "D") {
            let panSubstring = track2String[..<separatorIndex]
            return String(panSubstring)
        }
        return nil
    }
    
    private func formatExpiryDate(_ expiryData: Data) -> String? {
        guard expiryData.count >= 2 else { return nil }
        
        let yearByte = expiryData[0]
        let monthByte = expiryData[1]
        
        let year = String(format: "%02X", yearByte)
        let month = String(format: "%02X", monthByte)
        
        return "\(month)/\(year)"
    }
}

// MARK: - Extensions
extension String {
    var hexadecimalData: Data? {
        var data = Data(capacity: count / 2)
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: self, options: [], range: NSRange(startIndex..., in: self)) { match, _, _ in
            let byteString = (self as NSString).substring(with: match!.range)
            let num = UInt8(byteString, radix: 16)!
            data.append(num)
        }
        return data
    }
}

extension Data {
    var hexString: String {
        return map { String(format: "%02X", $0) }.joined()
    }
}

//enum NFCError: Error {
//    case notSupported
//    case invalidCardType
//    case connectionError
//    case readError
//}

enum NFCError: LocalizedError {
    case notSupported
    case invalidCardType
    case connectionError
    case readError
    case userCancelled
    case sessionTimeout
    
    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "NFC reading is not supported on this device"
        case .invalidCardType:
            return "This card type is not supported"
        case .connectionError:
            return "Failed to connect to the card"
        case .readError:
            return "Failed to read the card"
        case .userCancelled:
            return "Scanning was cancelled"
        case .sessionTimeout:
            return "Scanning timed out"
        }
    }
}
