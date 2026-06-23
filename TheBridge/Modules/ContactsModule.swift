// ContactsModule.swift – Contacts Tools
// TheBridge · Modules
//
// Four tools: contacts_health (open), contacts_search (open), contacts_get (open),
// contacts_resolve_handle (open).
// Uses CNContactStore for direct Contacts framework access — no AppleScript or Contacts.app required.
// Created by PKT-544: First-class Contacts module extracted from SystemModule.

import AppKit
@preconcurrency import Contacts
import Foundation
import MCP

// MARK: - ContactsModule

/// Provides CNContactStore-backed contact tools: health check, search, get, and handle resolution.
public enum ContactsModule {

    public static let moduleName = "contacts"

    // MARK: - TCC Helper

    /// Ensures Contacts access is authorized or limited. Triggers TCC prompt if `.notDetermined`.
    /// Throws with remediation message if denied or restricted.
    private static func requireContactsAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            let granted = try await Task { @MainActor in
                try await CNContactStore().requestAccess(for: .contacts)
            }.value
            if !granted {
                throw ContactsModuleError.accessDenied
            }
        case .denied, .restricted:
            throw ContactsModuleError.accessDenied
        @unknown default:
            throw ContactsModuleError.accessDenied
        }
    }

    // MARK: - E.164 Normalization

    /// Strips non-digit characters from a phone string, returns digits only.
    private static func digitsOnly(_ phone: String) -> String {
        phone.filter { $0.isNumber }
    }

    /// Attempts E.164 normalization for US numbers.
    /// - 10 digits → +1XXXXXXXXXX
    /// - 11 digits starting with 1 → +1XXXXXXXXXX
    /// - Already starts with + → return as-is with digits
    /// - Otherwise → nil (cannot normalize)
    private static func toE164(_ phone: String) -> String? {
        let digits = digitsOnly(phone)
        if phone.hasPrefix("+") {
            return "+" + digits
        }
        if digits.count == 10 {
            return "+1" + digits
        }
        if digits.count == 11 && digits.hasPrefix("1") {
            return "+" + digits
        }
        return nil
    }

    /// Builds a normalized phone object for output.
    private static func normalizedPhone(label: String, original: String) -> [String: Value] {
        let digits = digitsOnly(original)
        var result: [String: Value] = [
            "label": .string(label),
            "original": .string(original),
            "digitsOnly": .string(digits)
        ]
        if let e164 = toE164(original) {
            result["e164"] = .string(e164)
        }
        return result
    }

    // MARK: - Shared Keys

    /// Minimal keys for counting contacts.
    private static var identifierKeys: [CNKeyDescriptor] { [
        CNContactIdentifierKey as CNKeyDescriptor
    ] }

    /// Full keys for search and get results.
    private static var fullKeys: [CNKeyDescriptor] { [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
    ] }

    // MARK: - Registration

    /// Register all ContactsModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. contacts_health – open
        await router.register(ToolRegistration(
            name: "contacts_health",
            module: moduleName,
            tier: .open,
            description: "Probe Contacts permission + CNContactStore reachability. Run this first if contacts_* tools fail.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let status = CNContactStore.authorizationStatus(for: .contacts)
                let statusString: String
                switch status {
                case .authorized: statusString = "authorized"
                case .denied: statusString = "denied"
                case .restricted: statusString = "restricted"
                case .notDetermined: statusString = "notDetermined"
                @unknown default: statusString = "unknown"
                }

                var result: [String: Value] = [
                    "permission": .string(statusString),
                    "settings_url": .string("x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
                ]

                if status == .authorized {
                    result["contacts_available"] = .bool(true)
                    // Count contacts with minimal fetch
                    let store = CNContactStore()
                    var count = 0
                    let request = CNContactFetchRequest(keysToFetch: identifierKeys)
                    do {
                        try store.enumerateContacts(with: request) { _, _ in
                            count += 1
                        }
                        result["total_contacts"] = .int(count)
                    } catch {
                        result["total_contacts"] = .int(0)
                        result["count_error"] = .string(error.localizedDescription)
                    }
                    result["remediation"] = .null
                } else {
                    result["contacts_available"] = .bool(false)
                    if status == .notDetermined {
                        result["remediation"] = .string("Call any contacts tool to trigger the TCC permission prompt.")
                    } else {
                        result["remediation"] = .string("Enable Contacts access in System Settings > Privacy & Security > Contacts for The Bridge.")
                    }
                }

                return .object(result)
            }
        ))

        // MARK: 2. contacts_search – open (extracted from SystemModule, enhanced)
        await router.register(ToolRegistration(
            name: "contacts_search",
            module: moduleName,
            tier: .open,
            description: "Search the local Contacts app by name (default), phone, or email. For handle→contact resolution use contacts_resolve_handle.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Search query to match against contact fields")]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Fields to search: 'name', 'phone', 'email' (default: [\"name\"])")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "contacts_search", reason: "missing 'query'")
                }

                try await requireContactsAccess()

                let fields: [String] = {
                    if case .array(let arr) = args["fields"] {
                        return arr.compactMap { val in
                            if case .string(let s) = val { return s }
                            return nil
                        }
                    }
                    return ["name"]
                }()

                let store = CNContactStore()

                // Build predicates based on fields
                var predicates: [NSPredicate] = []
                if fields.contains("name") {
                    predicates.append(CNContact.predicateForContacts(matchingName: query))
                }
                if fields.contains("email") {
                    predicates.append(CNContact.predicateForContacts(matchingEmailAddress: query))
                }
                if fields.contains("phone") {
                    let digits = query.filter { $0.isNumber || $0 == "+" }
                    if !digits.isEmpty {
                        let phoneNumber = CNPhoneNumber(stringValue: digits)
                        predicates.append(CNContact.predicateForContacts(matching: phoneNumber))
                    }
                }

                // Fallback to name search if no predicates
                if predicates.isEmpty {
                    predicates.append(CNContact.predicateForContacts(matchingName: query))
                }

                // Fetch contacts for each predicate
                var allContacts: [CNContact] = []
                for predicate in predicates {
                    do {
                        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fullKeys)
                        allContacts.append(contentsOf: contacts)
                    } catch {
                        // Skip failed predicates, continue with others
                    }
                }

                // Deduplicate by identifier
                var seen = Set<String>()
                let unique = allContacts.filter { seen.insert($0.identifier).inserted }

                // Format results with contactId and normalized phones
                let results: [Value] = Array(unique.prefix(50)).map { contact in
                    formatContact(contact, full: false)
                }

                return .object([
                    "count": .int(results.count),
                    "query": .string(query),
                    "fieldsSearched": .array(fields.map { .string($0) }),
                    "contacts": .array(results)
                ])
            }
        ))

        // MARK: 3. contacts_get – open
        await router.register(ToolRegistration(
            name: "contacts_get",
            module: moduleName,
            tier: .open,
            description: "Fetch a full contact card by its CNContact.identifier UUID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "contactId": .object(["type": .string("string"), "description": .string("CNContact.identifier UUID")])
                ]),
                "required": .array([.string("contactId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let contactId) = args["contactId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "contacts_get", reason: "missing 'contactId'")
                }

                try await requireContactsAccess()

                let store = CNContactStore()
                let predicate = CNContact.predicateForContacts(withIdentifiers: [contactId])

                do {
                    let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fullKeys)
                    guard let contact = contacts.first else {
                        return .object(["error": .string("Contact not found: \(contactId)")])
                    }
                    return formatContact(contact, full: true)
                } catch {
                    return .object(["error": .string("Failed to fetch contact: \(error.localizedDescription)")])
                }
            }
        ))

        // MARK: 4. contacts_resolve_handle – open
        await router.register(ToolRegistration(
            name: "contacts_resolve_handle",
            module: moduleName,
            tier: .open,
            description: "Resolve a phone number (E.164 or partial) or email to the matching Contacts card. Critical step for Messages triage / attribution.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "handle": .object(["type": .string("string"), "description": .string("E.164 phone, partial digits, or email")]),
                    "region": .object(["type": .string("string"), "description": .string("ISO country code for phone normalization (default: \"US\")")])
                ]),
                "required": .array([.string("handle")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let handle) = args["handle"] else {
                    throw ToolRouterError.invalidArguments(toolName: "contacts_resolve_handle", reason: "missing 'handle'")
                }

                try await requireContactsAccess()

                let store = CNContactStore()
                let isEmail = handle.contains("@")
                let normalized = isEmail ? handle : (toE164(handle) ?? handle)

                if isEmail {
                    // Email resolution
                    let predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
                    do {
                        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fullKeys)
                        if let contact = contacts.first {
                            return .object([
                                "handle": .string(handle),
                                "normalizedHandle": .string(handle),
                                "confidence": .string("exact"),
                                "matchReason": .string("Email predicate match"),
                                "contact": formatContact(contact, full: false)
                            ])
                        }
                    } catch { /* fall through to no match */ }

                    return .object([
                        "handle": .string(handle),
                        "normalizedHandle": .string(handle),
                        "confidence": .string("none"),
                        "matchReason": .string("No contact found matching this handle"),
                        "contact": .null
                    ])
                }

                // Phone resolution
                let digits = digitsOnly(handle)

                // 1. Try exact E.164 match
                if let e164 = toE164(handle) {
                    let phoneNumber = CNPhoneNumber(stringValue: e164)
                    let predicate = CNContact.predicateForContacts(matching: phoneNumber)
                    do {
                        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fullKeys)
                        if let contact = contacts.first {
                            return .object([
                                "handle": .string(handle),
                                "normalizedHandle": .string(e164),
                                "confidence": .string("exact"),
                                "matchReason": .string("E.164 predicate match"),
                                "contact": formatContact(contact, full: false)
                            ])
                        }
                    } catch { /* fall through */ }
                }

                // 2. Try normalized digits match
                if !digits.isEmpty {
                    let phoneNumber = CNPhoneNumber(stringValue: digits)
                    let predicate = CNContact.predicateForContacts(matching: phoneNumber)
                    do {
                        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fullKeys)
                        if let contact = contacts.first {
                            return .object([
                                "handle": .string(handle),
                                "normalizedHandle": .string(normalized),
                                "confidence": .string("normalized"),
                                "matchReason": .string("Digits-only predicate match"),
                                "contact": formatContact(contact, full: false)
                            ])
                        }
                    } catch { /* fall through */ }
                }

                // 3. Try partial match — strip country code, try 7 and 10 digit variants
                let variants: [String] = {
                    var v: [String] = []
                    if digits.count > 10 && digits.hasPrefix("1") {
                        v.append(String(digits.dropFirst())) // drop country code
                    }
                    if digits.count >= 10 {
                        v.append(String(digits.suffix(10)))
                    }
                    if digits.count >= 7 {
                        v.append(String(digits.suffix(7)))
                    }
                    return v
                }()

                for variant in variants {
                    let phoneNumber = CNPhoneNumber(stringValue: variant)
                    let predicate = CNContact.predicateForContacts(matching: phoneNumber)
                    do {
                        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: fullKeys)
                        if let contact = contacts.first {
                            return .object([
                                "handle": .string(handle),
                                "normalizedHandle": .string(normalized),
                                "confidence": .string("partial"),
                                "matchReason": .string("Partial digit match (variant: \(variant))"),
                                "contact": formatContact(contact, full: false)
                            ])
                        }
                    } catch { /* continue */ }
                }

                // No match
                return .object([
                    "handle": .string(handle),
                    "normalizedHandle": .string(normalized),
                    "confidence": .string("none"),
                    "matchReason": .string("No contact found matching this handle"),
                    "contact": .null
                ])
            }
        ))
    }

    // MARK: - Contact Formatting

    /// Formats a CNContact into a Value object.
    /// - Parameter full: If true, includes all fields (for contacts_get). If false, compact (for search/resolve).
    private static func formatContact(_ contact: CNContact, full: Bool) -> Value {
        let displayName = CNContactFormatter.string(from: contact, style: .fullName)
            ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)

        let phones: [Value] = contact.phoneNumbers.map { phone in
            let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? "other")
            let original = phone.value.stringValue
            return .object(normalizedPhone(label: label, original: original))
        }

        let emails: [Value] = contact.emailAddresses.map { email in
            .object([
                "label": .string(CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "other")),
                "address": .string(email.value as String)
            ])
        }

        var entry: [String: Value] = [
            "contactId": .string(contact.identifier),
            "displayName": .string(displayName)
        ]

        if full {
            entry["givenName"] = .string(contact.givenName)
            entry["familyName"] = .string(contact.familyName)
            if !contact.organizationName.isEmpty {
                entry["organizationName"] = .string(contact.organizationName)
            }

            let addresses: [Value] = contact.postalAddresses.map { addr in
                let postal = addr.value
                var parts: [String] = []
                if !postal.street.isEmpty { parts.append(postal.street) }
                if !postal.city.isEmpty { parts.append(postal.city) }
                if !postal.state.isEmpty { parts.append(postal.state) }
                if !postal.postalCode.isEmpty { parts.append(postal.postalCode) }
                if !postal.country.isEmpty { parts.append(postal.country) }
                return .object([
                    "label": .string(CNLabeledValue<CNPostalAddress>.localizedString(forLabel: addr.label ?? "other")),
                    "formatted": .string(parts.joined(separator: ", "))
                ])
            }
            if !addresses.isEmpty { entry["postalAddresses"] = .array(addresses) }

            if let birthday = contact.birthday {
                var components: [String] = []
                if let year = birthday.year { components.append(String(format: "%04d", year)) }
                else { components.append("????") }
                if let month = birthday.month { components.append(String(format: "%02d", month)) }
                if let day = birthday.day { components.append(String(format: "%02d", day)) }
                if components.count == 3 {
                    entry["birthday"] = .string(components.joined(separator: "-"))
                }
            }
        } else {
            if !contact.organizationName.isEmpty {
                entry["organization"] = .string(contact.organizationName)
            }
        }

        if !phones.isEmpty { entry["phones"] = .array(phones) }
        if !emails.isEmpty { entry["emails"] = .array(emails) }

        return .object(entry)
    }

    // MARK: - Errors

    private enum ContactsModuleError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Contacts access not granted. Enable in System Settings > Privacy & Security > Contacts for The Bridge."
            }
        }
    }
}
