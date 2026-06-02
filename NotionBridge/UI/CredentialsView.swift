// CredentialsView.swift — Credentials Settings Tab
// PKT-372: Type-grouped credential display (Passwords, Cards)
// PKT-486: Manual credential creation forms (Add Password, Add Card)
// Scope IN D5: "Credentials" tab in SettingsWindow — grouped by type

import SwiftUI

// MARK: - FormFeedback

/// Inline feedback message for credential forms.
private struct FormFeedback {
    let message: String
    let isError: Bool
}

/// Settings tab showing stored credentials grouped by type (Passwords, Cards).
/// Cards display last4 + brand + expiry. All entries support delete.
/// PKT-486: Collapsible forms for adding passwords and cards inline.
struct CredentialsView: View {
    @State private var credentials: [CredentialEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var entryToDelete: (service: String, account: String)?
    @State private var showDeleteConfirmation = false
    @State private var credentialsEnabledUI = UserDefaults.standard.bool(forKey: CredentialsFeature.userDefaultsKey)
    @State private var enablingCredentials = false

    // Add Password form state
    @State private var showAddPassword = false
    @State private var pwService = ""
    @State private var pwAccount = ""
    @State private var pwPassword = ""
    @State private var pwSaving = false
    @State private var pwFeedback: FormFeedback?

    // Add Card form state
    @State private var showAddCard = false
    @State private var cardName = ""      // PKT-573: cardholder name
    @State private var cardNumber = ""
    @State private var cardExpiry = ""
    @State private var cardCVC = ""
    @State private var cardZip = ""       // PKT-573: billing ZIP
    @State private var cardSaving = false
    @State private var cardFeedback: FormFeedback?

    // PKT-441: Add API Key form state
    @State private var showAddApiKey = false
    @State private var akName = ""
    @State private var akValue = ""
    @State private var akSaving = false
    @State private var akFeedback: FormFeedback?

    private let manager = CredentialManager.shared

    private var passwords: [CredentialEntry] {
        credentials.filter { $0.type == .password }
    }

    private var cards: [CredentialEntry] {
        credentials.filter { $0.type == .card }
    }

    // PKT-441: API Keys section
    private var apiKeys: [CredentialEntry] {
        credentials.filter { $0.type == .apiKey }
    }

    var body: some View {
        Form {
            // MARK: API Keys
            Section("Notion Integrations") {
                ConnectionsManagementView()
            }

            // MARK: Setup Instructions
            Section {
                Link(destination: URL(string: "https://www.notion.so/profile/integrations")!) {
                    HStack {
                        Image(systemName: "globe")
                        Text("Create a Notion integration at notion.so/profile/integrations")
                            .font(.caption)
                    }
                }
            }



            // MARK: Apple Keychain Credentials
            Section {
                Toggle(isOn: Binding(
                    get: { credentialsEnabledUI },
                    set: { newValue in
                        if newValue {
                            Task { await setCredentialsEnabled() }
                        } else {
                            UserDefaults.standard.set(false, forKey: CredentialsFeature.userDefaultsKey)
                            credentialsEnabledUI = false
                            showAddPassword = false
                            showAddCard = false
                            showAddApiKey = false
                            NotificationCenter.default.post(name: .notionBridgeCredentialsFeatureDidChange, object: nil)
                        }
                    }
                )) {
                    Text("Apple Keychain Credentials")
                }
                .disabled(enablingCredentials)
                .accessibilityLabel("Enable Apple Keychain Credentials")

                if !credentialsEnabledUI {
                    Text(
                        "When off, credential MCP tools are unavailable and this tab stays read-minimal. Turn on to store passwords and tokenized cards locally."
                    )
                    .font(.callout)
                    .foregroundStyle(BridgeColors.secondary)
                }
            }

            if credentialsEnabledUI {
                // MARK: Onboarding / all-foreign-filtered banner (PKT-934 W3)
                // When the feature is on but no Bridge-scoped credentials are
                // present, three bare "No saved X" rows read like an error
                // and give a brand-new user no next step. They also can't
                // tell an empty keychain apart from one whose entries were
                // all filtered out by the v3.6.x scoping hotfix (foreign
                // keychain items are intentionally hidden here). A single
                // onboarding banner covers both: empty-new and
                // all-foreign-filtered. Suppressed once any add-form is open
                // or any Bridge credential exists.
                if credentials.isEmpty && !showAddApiKey && !showAddPassword && !showAddCard {
                    Section {
                        BridgeEmptyState(
                            systemImage: "key.horizontal",
                            title: "No Bridge credentials yet",
                            body: "Add an API key, password, or tokenized card below to store it in the macOS Keychain with biometric protection. Only credentials created here appear in this list — existing Keychain items from other apps are intentionally hidden."
                        )
                    }
                }

                // MARK: API Keys (PKT-441)
                Section("API Keys") {
                    if apiKeys.isEmpty && !showAddApiKey {
                        Text("No saved API keys")
                            .foregroundStyle(BridgeColors.secondary)
                            .font(.caption)
                    } else {
                        ForEach(0..<apiKeys.count, id: \.self) { idx in
                            apiKeyRow(apiKeys[idx])
                        }
                    }

                    addCredentialRow(title: "Add API Key", isExpanded: $showAddApiKey) {
                        addApiKeyForm
                    }
                }

                // MARK: Passwords
                Section("Passwords") {
                    if passwords.isEmpty && !showAddPassword {
                        Text("No saved passwords")
                            .foregroundStyle(BridgeColors.secondary)
                            .font(.caption)
                    } else {
                        ForEach(0..<passwords.count, id: \.self) { idx in
                            passwordRow(passwords[idx])
                        }
                    }

                    addCredentialRow(title: "Add Password", isExpanded: $showAddPassword) {
                        addPasswordForm
                    }
                }

                // MARK: Cards
                Section("Cards") {
                    if cards.isEmpty && !showAddCard {
                        Text("No saved cards")
                            .foregroundStyle(BridgeColors.secondary)
                            .font(.caption)
                    } else {
                        ForEach(0..<cards.count, id: \.self) { idx in
                            cardRow(cards[idx])
                        }
                    }

                    addCredentialRow(title: "Add Card", isExpanded: $showAddCard) {
                        addCardForm
                    }
                }

                // MARK: Footer
                Section {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(BridgeColors.error)
                    }

                    HStack {
                        Button("Refresh") {
                            loadCredentials()
                        }
                        .font(.caption)

                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text("Stored in macOS Keychain with biometric protection.")
                        .font(.caption2)
                        .foregroundStyle(BridgeColors.muted)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            credentialsEnabledUI = UserDefaults.standard.bool(forKey: CredentialsFeature.userDefaultsKey)
        }
        .task(id: credentialsEnabledUI) {
            guard credentialsEnabledUI else {
                isLoading = false
                return
            }
            loadCredentials()
        }
        .confirmationDialog(
            "Delete Credential?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = entryToDelete {
                    Task { await deleteCredential(service: target.service, account: target.account) }
                }
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            if let target = entryToDelete {
                Text("Delete \"\(target.service) / \(target.account)\"? This cannot be undone.")
            }
        }
    }

    @MainActor
    private func setCredentialsEnabled() async {
        enablingCredentials = true
        defer { enablingCredentials = false }
        do {
            try await CredentialManager.shared.requireBiometric(reason: "Enable Keychain-backed credentials for Notion Bridge")
            UserDefaults.standard.set(true, forKey: CredentialsFeature.userDefaultsKey)
            credentialsEnabledUI = true
            loadCredentials()
            NotificationCenter.default.post(name: .notionBridgeCredentialsFeatureDidChange, object: nil)
        } catch {
            credentialsEnabledUI = false
        }
    }

    @ViewBuilder
    private func addCredentialRow<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.medium)
                    Text(title)
                        .font(.body)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BridgeColors.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Add Password Form

    @ViewBuilder
    private var addPasswordForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Service", text: $pwService)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            TextField("Account", text: $pwAccount)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            SecureField("Password", text: $pwPassword)
                    .textContentType(.none)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if let feedback = pwFeedback {
                feedbackLabel(feedback)
            }

            HStack {
                Button("Save Password") {
                    Task { await savePassword() }
                }
                .disabled(pwSaving || pwService.trimmingCharacters(in: .whitespaces).isEmpty
                          || pwAccount.trimmingCharacters(in: .whitespaces).isEmpty
                          || pwPassword.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if pwSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Add Card Form

    @ViewBuilder
    private var addCardForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            // PKT-573: Cardholder Name
            TextField("Cardholder Name", text: $cardName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            TextField("Card Number", text: $cardNumber)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 8) {
                TextField("MM/YY", text: $cardExpiry)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 80)

                TextField("CVC", text: $cardCVC)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 60)
            }

            // PKT-573: ZIP Code
            TextField("ZIP Code", text: $cardZip)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(maxWidth: 120)

            if let feedback = cardFeedback {
                feedbackLabel(feedback)
            }

            HStack {
                Button("Save Card") {
                    Task { await saveCard() }
                }
                .disabled(cardSaving
                          || cardName.trimmingCharacters(in: .whitespaces).isEmpty
                          || cardNumber.isEmpty
                          || cardExpiry.isEmpty || cardCVC.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if cardSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Feedback Label

    @ViewBuilder
    private func feedbackLabel(_ feedback: FormFeedback) -> some View {
        HStack(spacing: 4) {
            Image(systemName: feedback.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
            Text(feedback.message)
        }
        .font(.caption)
        .foregroundStyle(feedback.isError ? BridgeColors.error : .green)
    }

    // MARK: - Row Views

    // MARK: - API Key Row (PKT-441)

    @ViewBuilder
    private func apiKeyRow(_ entry: CredentialEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.service.replacingOccurrences(of: "api_key:", with: "").capitalized)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                if let maskedValue = entry.metadata.last4 {
                    Text("••••\(maskedValue)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(entry.account)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(role: .destructive) {
                entryToDelete = (service: entry.service, account: entry.account)
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func passwordRow(_ entry: CredentialEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.service)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(entry.account)
                    .font(.caption)
                    .foregroundStyle(BridgeColors.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) {
                entryToDelete = (service: entry.service, account: entry.account)
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func cardRow(_ entry: CredentialEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BridgeSpacing.xs) {
                    if let brand = entry.metadata.brand {
                        Text(brand.uppercased())
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    if let last4 = entry.metadata.last4 {
                        Text("•••• \(last4)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                HStack(spacing: BridgeSpacing.xs) {
                    Text(entry.account)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                        .lineLimit(1)
                    if let expMonth = entry.metadata.expMonth,
                       let expYear = entry.metadata.expYear {
                        Text("Exp \(String(format: "%02d", expMonth))/\(expYear)")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.muted)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                entryToDelete = (service: entry.service, account: entry.account)
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Save Actions

    // MARK: - Add API Key Form (PKT-441)

    @ViewBuilder
    private var addApiKeyForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name (e.g. Stripe)", text: $akName)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            SecureField("API Key", text: $akValue)
                    .textContentType(.none)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if let feedback = akFeedback {
                feedbackLabel(feedback)
            }

            HStack {
                Button("Save API Key") {
                    Task { await saveApiKey() }
                }
                .disabled(akSaving || akName.trimmingCharacters(in: .whitespaces).isEmpty
                          || akValue.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if akSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func saveApiKey() async {
        akFeedback = nil
        akSaving = true
        defer { akSaving = false }

        let name = akName.trimmingCharacters(in: .whitespaces).lowercased()
        let value = akValue.trimmingCharacters(in: .whitespaces)

        do {
            let last4 = String(value.suffix(4))
            let metadata = CredentialMetadata(last4: last4)
            _ = try await manager.save(
                service: "api_key:\(name)",
                account: name,
                password: value,
                type: .apiKey,
                metadata: metadata
            )
            akFeedback = FormFeedback(message: "API key saved.", isError: false)
            akName = ""
            akValue = ""
            loadCredentials()
        } catch {
            akFeedback = FormFeedback(message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Save Actions

    private func savePassword() async {
        pwFeedback = nil
        pwSaving = true
        defer { pwSaving = false }

        let service = pwService.trimmingCharacters(in: .whitespaces)
        let account = pwAccount.trimmingCharacters(in: .whitespaces)

        do {
            _ = try await manager.save(
                service: service,
                account: account,
                password: pwPassword,
                type: .password
            )
            pwFeedback = FormFeedback(message: "Password saved.", isError: false)
            pwService = ""
            pwAccount = ""
            pwPassword = ""
            loadCredentials()
        } catch {
            pwFeedback = FormFeedback(message: error.localizedDescription, isError: true)
        }
    }

    private func saveCard() async {
        cardFeedback = nil

        // Strip spaces/dashes from card number
        let cleanNumber = cardNumber
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        // Validate card number via Luhn
        guard luhnCheck(cleanNumber) else {
            cardFeedback = FormFeedback(message: "Invalid card number.", isError: true)
            return
        }

        // Parse and validate expiry (MM/YY)
        guard let (expMonth, expYear) = parseExpiry(cardExpiry) else {
            cardFeedback = FormFeedback(message: "Invalid expiry. Use MM/YY.", isError: true)
            return
        }
        guard !isExpiryPast(month: expMonth, year: expYear) else {
            cardFeedback = FormFeedback(message: "Card is expired.", isError: true)
            return
        }

        // Validate CVC (3–4 digits)
        let cleanCVC = cardCVC.filter { $0.isNumber }
        guard cleanCVC.count >= 3, cleanCVC.count <= 4 else {
            cardFeedback = FormFeedback(message: "CVC must be 3 or 4 digits.", isError: true)
            return
        }

        cardSaving = true
        defer { cardSaving = false }

        // PKT-573: gather cardholder name + ZIP
        let trimmedName = cardName.trimmingCharacters(in: .whitespaces)
        let trimmedZip = cardZip.trimmingCharacters(in: .whitespaces)
        let metadata = CredentialMetadata(
            expMonth: expMonth,
            expYear: expYear,
            cardholderName: trimmedName.isEmpty ? nil : trimmedName,
            zipCode: trimmedZip.isEmpty ? nil : trimmedZip
        )

        do {
            // CredentialManager.save() handles Stripe tokenization internally
            // for .card type — raw card number is never stored in Keychain.
            _ = try await manager.save(
                service: "card",
                account: "card-\(cleanNumber.suffix(4))",
                password: cleanNumber,
                type: .card,
                metadata: metadata
            )
            cardFeedback = FormFeedback(message: "Card saved and tokenized.", isError: false)
            cardName = ""
            cardNumber = ""
            cardExpiry = ""
            cardCVC = ""
            cardZip = ""
            loadCredentials()
        } catch {
            cardFeedback = FormFeedback(message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Validation Helpers

    /// Luhn algorithm check for card number validity.
    private func luhnCheck(_ number: String) -> Bool {
        guard number.count >= 13, number.count <= 19,
              number.allSatisfy({ $0.isNumber }) else { return false }
        var sum = 0
        let reversed = Array(number.reversed())
        for (i, ch) in reversed.enumerated() {
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

    /// Parse "MM/YY" string into (month, four-digit year).
    private func parseExpiry(_ raw: String) -> (Int, Int)? {
        let parts = raw.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let shortYear = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        let year = shortYear < 100 ? 2000 + shortYear : shortYear
        return (month, year)
    }

    /// Returns true if the given month/year is in the past.
    private func isExpiryPast(month: Int, year: Int) -> Bool {
        let cal = Calendar.current
        let now = Date()
        let currentMonth = cal.component(.month, from: now)
        let currentYear = cal.component(.year, from: now)
        if year < currentYear { return true }
        if year == currentYear && month < currentMonth { return true }
        return false
    }

    // MARK: - Data Loading

    private func loadCredentials() {
        isLoading = true
        errorMessage = nil
        do {
            credentials = try manager.list()
            isLoading = false
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func deleteCredential(service: String, account: String) async {
        do {
            _ = try await manager.deleteCredential(service: service, account: account)
            loadCredentials()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
        entryToDelete = nil
    }
}
