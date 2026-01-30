import SwiftUI

struct ApprovalPromptView: View {
    let request: PendingAuthRequestInfo
    let onApprove: (String?) -> Void
    let onDeny: () -> Void

    @State private var sessionName: String = ""
    @State private var confirmedAtMac: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Approve Access")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("This request must be approved on your Mac.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Details + controls
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Confirm Code")
                            .font(.headline)
                        Text(request.confirmCode)
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                            )
                    }

                    LabeledContent("Client") { Text(request.clientId).textSelection(.enabled) }
                    LabeledContent("Redirect") { Text(request.redirectUri).textSelection(.enabled) }
                    LabeledContent("Scope") { Text(request.scope.isEmpty ? "(none)" : request.scope).textSelection(.enabled) }
                    LabeledContent("Request from") { Text(request.source).textSelection(.enabled) }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Session Name")
                        .font(.headline)
                    TextField("Optional (e.g. \"Claude on laptop\")", text: $sessionName)
                        .textFieldStyle(.roundedBorder)

                    Toggle("I am at my Mac and I approve this request.", isOn: $confirmedAtMac)
                }

                Text("Only approve if you initiated this connection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)

            Divider()

            // Footer
            HStack {
                Button("Deny") {
                    onDeny()
                }
                .buttonStyle(SecondaryButtonStyle())

                Spacer()

                Button("Approve") {
                    let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onApprove(trimmed.isEmpty ? nil : trimmed)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!confirmedAtMac)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 520)
    }
}
