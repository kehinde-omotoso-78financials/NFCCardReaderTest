import SwiftUI
import CoreNFC

struct ContentView: View {
    @State private var cardData: NFCCardReaderBase.CardData?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isScanning = false
    
    private let nfcReader = NFCCardReaderBase()
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "creditcard.fill")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .font(.system(size: 50))
            
            Text("NFC Card Reader")
                .font(.title)
            
            if let cardData = cardData {
                VStack(alignment: .leading, spacing: 10) {
                    InfoRow(title: "Card Number", value: cardData.pan)
                    InfoRow(title: "Expiry Date", value: cardData.expiryDate)
                    InfoRow(title: "Cardholder", value: cardData.cardholderName)
                    InfoRow(title: "Card Type", value: cardData.applicationLabel)
                    InfoRow(title: "AID", value: cardData.aid)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            } else {
                Text("No card scanned")
                    .foregroundColor(.gray)
                    .padding()
            }
            
            Button(action: startScanning) {
                HStack {
                    Image(systemName: "wave.3.right")
                    Text(isScanning ? "Scanning..." : "Scan Card")
                }
                .frame(minWidth: 200)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isScanning)
        }
        .padding()
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {
                showError = false
            }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func startScanning() {
        guard NFCTagReaderSession.readingAvailable else {
            errorMessage = "NFC scanning is not supported on this device"
            showError = true
            return
        }
        
        isScanning = true
        
        // Add timeout handler
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if isScanning {
                isScanning = false
            }
        }
        
        nfcReader.startScanning { result in
            DispatchQueue.main.async {
                isScanning = false
                
                switch result {
                case .success(let data):
                    cardData = data
                case .failure(let error):
                    if let nfcError = error as? NFCReaderError,
                       nfcError.code == .readerSessionInvalidationErrorUserCanceled {
                        // Don't show error for user cancellation
                        return
                    }
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// Helper view for displaying card information rows
struct InfoRow: View {
    let title: String
    let value: String?
    
    var body: some View {
        HStack {
            Text(title + ":")
                .fontWeight(.medium)
            Text(value ?? "N/A")
                .foregroundColor(value == nil ? .gray : .primary)
        }
    }
}

// Preview provider for SwiftUI canvas
#Preview {
    ContentView()
}
