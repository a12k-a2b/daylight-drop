import SwiftUI
import AppKit
import DaylightDropTransport

/// Multi-line Quick AI Prompt & Text Scratchpad with instant `Cmd + Enter` dispatch.
public struct ScratchpadView: View {
    @Binding public var text: String
    @ObservedObject var stagingManager: StagingManager
    public var onDispatch: ((String) -> Void)?
    
    @FocusState private var isFocused: Bool
    
    public init(
        text: Binding<String>,
        stagingManager: StagingManager = .shared,
        onDispatch: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.stagingManager = stagingManager
        self.onDispatch = onDispatch
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("QUICK PROMPT & SCRATCHPAD")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SolOSTokens.os400)
                    .tracking(0.8)
                Spacer()
                Text("⌘ + ↩ to Beam")
                    .font(.system(size: 10))
                    .foregroundColor(SolOSTokens.os300)
            }
            .padding(.horizontal, 12)
            
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                    .fill(SolOSTokens.os0)
                    .overlay(
                        RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                            .stroke(isFocused ? SolOSTokens.os900 : SolOSTokens.os100, lineWidth: 1)
                    )
                
                if text.isEmpty {
                    Text("Type prompt or note to beam to Daylight clipboard...")
                        .font(.system(size: 12))
                        .foregroundColor(SolOSTokens.os300)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                
                VStack(spacing: 0) {
                    TextEditor(text: $text)
                        .font(.system(size: 12))
                        .foregroundColor(SolOSTokens.os900)
                        .tint(SolOSTokens.os900)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .focused($isFocused)
                        .frame(minHeight: 52, maxHeight: 80)
                        .onKeyPress { keyPress in
                            if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                                dispatchPrompt()
                                return .handled
                            }
                            return .ignored
                        }
                    
                    HStack {
                        Spacer()
                        Button(action: dispatchPrompt) {
                            HStack(spacing: 3) {
                                Text("Beam")
                                    .font(.system(size: 10, weight: .semibold))
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 8))
                            }
                            .foregroundColor(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? SolOSTokens.os300 : SolOSTokens.os0)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? SolOSTokens.os150 : SolOSTokens.os900
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding(.trailing, 6)
                        .padding(.bottom, 6)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .environment(\.colorScheme, .light)
    }
    
    public func dispatchPrompt() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let promptToSend = trimmed
        text = ""
        
        if let onDispatch = onDispatch {
            onDispatch(promptToSend)
            return
        }
        
        // Stage locally to ~/DaylightDrop/outgoing/prompt_<timestamp>.txt
        let staged = stagingManager.stageOutboundPrompt(prompt: promptToSend)
        stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
        
        // Beam via TransportManager
        Task {
            do {
                _ = try await TransportManager.shared.sendText(text: promptToSend, type: "prompt")
                stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
            } catch {
                NSLog("[ScratchpadView] Error sending prompt: %@", error.localizedDescription)
                stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
            }
        }
    }
}
