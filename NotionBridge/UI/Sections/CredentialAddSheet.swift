// CredentialAddSheet.swift — Premium add / replace-secret sheet.
// v3.7.6 Wave 4a (premium Credentials vault). Replaces the legacy Form-based
// CRUD (CredentialsView). A clean enterprise sheet that supports the existing
// CredentialTypes (API key, password, card), validates required fields, and
// calls CredentialManager.save (the biometric gate already fires inside save).
//
// Two modes:
//   • .add               — pick a type, enter a new credential.
//   • .replace(service…) — "Rotate" / "Reconnect": prefilled to one service,
//                          type locked, only the secret is replaced.
//
// All color comes from adaptive BridgeTokens (no hardcoded Color.white/black).

import SwiftUI

// MARK: - Mode

public enum CredentialSheetMode: Equatable {
    /// Add a brand-new credential (type picker shown).
    case add
    /// Replace the secret for an existing credential (type/service locked).
    /// `reconnect == true` frames the copy as re-auth (revoked credential).
    case replace(service: String, account: String, type: CredentialType, reconnect: Bool)
}

// MARK: - Sheet

public struct CredentialAddSheet: View {
    let mode: CredentialSheetMode
    /// Called after a successful save so the vault can reload + revalidate.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Type selection (locked in replace mode).
    @State private var selectedType: CredentialType

    // API key fields.
    @State private var akName: String
    @State private var akValue: String = ""

    // Password fields.
    @State private var pwService: String
    @State private var pwAccount: String
    @State private var pwValue: String = ""

    // Card fields.
    @State private var cardName: String = ""
    @State private var cardNumber: String = ""
    @State private var cardExpiry: String = ""
    @State private var cardCVC: String = ""
    @State private var cardZip: String = ""

    @State private var saving = false
    @State private var errorText: String?

    public init(mode: CredentialSheetMode, onSaved: @escaping () -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            _selectedType = State(initialValue: .apiKey)
            _akName = State(initialValue: "")
            _pwService = State(initialValue: "")
            _pwAccount = State(initialValue: "")
        case .replace(let service, let account, let type, _):
            _selectedType = State(initialValue: type)
            // Prefill the identity fields from the existing credential so the
            // operator only re-enters the secret.
            let provider = CredentialValidationMapper.normalizedProvider(forService: service)
            _akName = State(initialValue: provider)
            _pwService = State(initialValue: service)
            _pwAccount = State(initialValue: account)
        }
    }

    private var isReplace: Bool {
        if case .replace = mode { return true }
        return false
    }

    private var isReconnect: Bool {
        if case .replace(_, _, _, let reconnect) = mode { return reconnect }
        return false
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(BridgeTokens.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !isReplace {
                        typePicker
                    }
                    formFields
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(BridgeTokens.badText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider().overlay(BridgeTokens.hairline)
            footer
        }
        .frame(width: 460)
        .frame(minHeight: 360)
        .background(BridgeTokens.bgRaised)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BridgeTokens.accent.opacity(0.22))
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                Image(systemName: isReconnect ? "arrow.triangle.2.circlepath" : (isReplace ? "key.horizontal.fill" : "plus.circle.fill"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BridgeTokens.accentLink)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(BridgeTokens.fg4)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var title: String {
        if isReconnect { return "Reconnect \(displayName)" }
        if isReplace { return "Rotate \(displayName)" }
        return "Add credential"
    }

    private var subtitle: String {
        if isReplace {
            return "Enter a fresh secret — the existing entry is replaced in your Keychain."
        }
        return "Stored in your macOS Keychain. Bridge never writes plaintext to disk."
    }

    private var displayName: String {
        let provider = CredentialValidationMapper.normalizedProvider(forService: pwService)
        switch selectedType {
        case .apiKey:   return akName.isEmpty ? "API key" : akName.capitalized
        case .password: return provider.isEmpty ? "password" : provider.capitalized
        case .card:     return "card"
        case .unknown:  return "credential"
        }
    }

    // MARK: - Type picker

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Type")
            Picker("", selection: $selectedType) {
                Text("API key").tag(CredentialType.apiKey)
                Text("Password").tag(CredentialType.password)
                Text("Card").tag(CredentialType.card)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Form fields

    @ViewBuilder
    private var formFields: some View {
        switch selectedType {
        case .apiKey:
            field("Name", text: $akName, placeholder: "e.g. Stripe, OpenAI", mono: true, disabled: isReplace)
            secureField("API key", text: $akValue, placeholder: "Paste the secret")
        case .password:
            field("Service", text: $pwService, placeholder: "e.g. internal-portal", mono: true, disabled: isReplace)
            field("Account", text: $pwAccount, placeholder: "username or email", disabled: isReplace)
            secureField("Password", text: $pwValue, placeholder: "Paste the secret")
        case .card:
            field("Cardholder name", text: $cardName, placeholder: "Name on card")
            field("Card number", text: $cardNumber, placeholder: "1234 5678 9012 3456", mono: true)
            HStack(spacing: 10) {
                field("Expiry (MM/YY)", text: $cardExpiry, placeholder: "08/29")
                field("CVC", text: $cardCVC, placeholder: "123")
            }
            field("ZIP / postal code", text: $cardZip, placeholder: "Billing ZIP")
            Text("The raw card number is tokenized through Stripe before storage — only the token + last 4 are kept.")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.fg4)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().controlSize(.small) }
                    Text(saveLabel)
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(saving || !isValid)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var saveLabel: String {
        if isReconnect { return "Reconnect" }
        if isReplace { return "Rotate" }
        return "Save"
    }

    // MARK: - Field builders

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(BridgeTokens.fg4)
    }

    @ViewBuilder
    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        mono: Bool = false,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(disabled ? BridgeTokens.fg4 : BridgeTokens.fg1)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .disabled(disabled)
        }
    }

    @ViewBuilder
    private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            SecureField(placeholder, text: text)
                .textContentType(.none)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(BridgeTokens.fg1)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        switch selectedType {
        case .apiKey:
            return !akName.trimmingCharacters(in: .whitespaces).isEmpty && !akValue.isEmpty
        case .password:
            return !pwService.trimmingCharacters(in: .whitespaces).isEmpty
                && !pwAccount.trimmingCharacters(in: .whitespaces).isEmpty
                && !pwValue.isEmpty
        case .card:
            return !cardName.trimmingCharacters(in: .whitespaces).isEmpty
                && !cardNumber.isEmpty && !cardExpiry.isEmpty && !cardCVC.isEmpty
        case .unknown:
            return false
        }
    }

    // MARK: - Save

    private func save() async {
        errorText = nil
        saving = true
        defer { saving = false }
        do {
            switch selectedType {
            case .apiKey:    try await saveApiKey()
            case .password:  try await savePassword()
            case .card:      try await saveCard()
            case .unknown:   return
            }
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveApiKey() async throws {
        let name = akName.trimmingCharacters(in: .whitespaces).lowercased()
        let value = akValue.trimmingCharacters(in: .whitespaces)
        let last4 = String(value.suffix(4))
        _ = try await CredentialManager.shared.save(
            service: "api_key:\(name)",
            account: name,
            password: value,
            type: .apiKey,
            metadata: CredentialMetadata(last4: last4)
        )
    }

    private func savePassword() async throws {
        _ = try await CredentialManager.shared.save(
            service: pwService.trimmingCharacters(in: .whitespaces),
            account: pwAccount.trimmingCharacters(in: .whitespaces),
            password: pwValue,
            type: .password
        )
    }

    private func saveCard() async throws {
        let cleanNumber = cardNumber
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard CredentialCardValidation.luhn(cleanNumber) else {
            throw CredentialFormError.invalid("Invalid card number.")
        }
        guard let (expMonth, expYear) = CredentialCardValidation.parseExpiry(cardExpiry) else {
            throw CredentialFormError.invalid("Invalid expiry. Use MM/YY.")
        }
        guard !CredentialCardValidation.isExpiryPast(month: expMonth, year: expYear) else {
            throw CredentialFormError.invalid("Card is expired.")
        }
        let cleanCVC = cardCVC.filter(\.isNumber)
        guard cleanCVC.count >= 3, cleanCVC.count <= 4 else {
            throw CredentialFormError.invalid("CVC must be 3 or 4 digits.")
        }
        let trimmedName = cardName.trimmingCharacters(in: .whitespaces)
        let trimmedZip = cardZip.trimmingCharacters(in: .whitespaces)
        _ = try await CredentialManager.shared.save(
            service: "card",
            account: "card-\(cleanNumber.suffix(4))",
            password: cleanNumber,
            type: .card,
            metadata: CredentialMetadata(
                expMonth: expMonth,
                expYear: expYear,
                cardholderName: trimmedName.isEmpty ? nil : trimmedName,
                zipCode: trimmedZip.isEmpty ? nil : trimmedZip
            )
        )
    }
}

// MARK: - Form errors + card validation (pure)

enum CredentialFormError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let m): return m }
    }
}

/// Pure card-field validators (Luhn + expiry parse). Carried over from the
/// retired CredentialsView so card adds keep the same guardrails.
public enum CredentialCardValidation {
    public static func luhn(_ number: String) -> Bool {
        guard number.count >= 13, number.count <= 19,
              number.allSatisfy({ $0.isNumber }) else { return false }
        var sum = 0
        for (i, ch) in number.reversed().enumerated() {
            guard let digit = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    public static func parseExpiry(_ raw: String) -> (Int, Int)? {
        let parts = raw.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let shortYear = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              (1...12).contains(month) else { return nil }
        let year = shortYear < 100 ? 2000 + shortYear : shortYear
        return (month, year)
    }

    public static func isExpiryPast(month: Int, year: Int, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)
        if year < currentYear { return true }
        if year == currentYear && month < currentMonth { return true }
        return false
    }
}
