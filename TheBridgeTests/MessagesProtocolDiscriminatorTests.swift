// MessagesProtocolDiscriminatorTests.swift
// TheBridge · Tests
//
// #303 / epic #301 — outbound protocol discriminator (reopen-class of #198).
// Hermetic: no live Messages.app send, no chat.db required.

import Foundation
import MCP
import TheBridgeLib

func runMessagesProtocolDiscriminatorTests() async {
    print("\n📡 Messages protocol discriminator (#303)")

    await test("#303 parseTarget: recipient phone is 1:1 with no declared service") {
        let target = MessagesProtocolDiscriminator.parseTarget(
            recipient: "+16056013705",
            chatIdentifier: nil
        )
        try expect(target == .oneToOne(handle: "+16056013705", declaredThreadService: nil))
    }

    await test("#303 parseTarget: service-prefixed iMessage/SMS/RCS/any bind 1:1") {
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("iMessage;-;+16056013705")
                == .oneToOne(handle: "+16056013705", declaredThreadService: "iMessage")
        )
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("SMS;-;+12537920959")
                == .oneToOne(handle: "+12537920959", declaredThreadService: "SMS")
        )
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("RCS;-;+17575257951")
                == .oneToOne(handle: "+17575257951", declaredThreadService: "RCS")
        )
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("any;-;+17575257951")
                == .oneToOne(handle: "+17575257951", declaredThreadService: nil),
            "any;-;handle is 1:1 inherit, not a declared service"
        )
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("ada@example.com")
                == .oneToOne(handle: "ada@example.com", declaredThreadService: nil)
        )
    }

    await test("#303 parseTarget: group ids stay off the 1:1 discriminator") {
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("chat123456789") == .group("chat123456789")
        )
        try expect(
            MessagesProtocolDiscriminator.parseChatIdentifier("677927082d92462b9e1ddc5450b9ae10")
                == .group("677927082d92462b9e1ddc5450b9ae10")
        )
        try expect(
            MessagesProtocolDiscriminator.parseTarget(
                recipient: "chat123456789",
                chatIdentifier: nil
            ) == nil,
            "raw chatNNNN recipient must stay the ghost-thread refusal, not a group send"
        )
    }

    await test("#303 exact lookup keys are canonical + prefixed guids, never LIKE") {
        let keys = MessagesProtocolDiscriminator.exactLookupKeys(for: "6056013705")
        try expect(keys.contains("6056013705"))
        try expect(keys.contains("+16056013705"), "US 10-digit must add E.164")
        try expect(keys.contains("iMessage;-;+16056013705"))
        try expect(keys.contains("SMS;-;+16056013705"))
        try expect(keys.contains("RCS;-;+16056013705"))
        try expect(!keys.contains(where: { $0.contains("%") }), "no LIKE wildcards")
        let padded = MessagesProtocolDiscriminator.paddedLookupKeys(keys)
        try expect(padded.count == MessagesProtocolDiscriminator.lookupSlotCount)
        try expect(padded.contains("+16056013705"))
    }

    await test("#303 Veronica specimen: inbound iMessage wins over outbound SMS") {
        let rows: [[String: Any]] = [
            ["is_from_me": 1, "service": "SMS", "handle_id": "+16056013705",
             "chat_guid": "SMS;-;+16056013705", "service_name": "SMS", "participant_count": 1],
            ["is_from_me": 0, "service": "iMessage", "handle_id": "+16056013705",
             "chat_guid": "iMessage;-;+16056013705", "service_name": "iMessage", "participant_count": 1]
        ]
        let target = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+16056013705", declaredThreadService: nil
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: target) == "iMessage",
            "ROWID 54580-class inbound iMessage must win"
        )
        switch MessagesModule.resolveSendService(requested: nil, liveInboundRaw: "iMessage") {
        case .use(let service):
            try expect(service == .iMessage)
        case .refuse(let reason):
            throw TestError.assertion("Veronica inherit must send iMessage, got \(reason)")
        }
        switch MessagesModule.resolveSendService(requested: "SMS", liveInboundRaw: "iMessage") {
        case .refuse(let reason):
            try expect(reason.contains("does not match live inbound"))
        case .use:
            throw TestError.assertion("explicit SMS on Veronica iMessage must fail closed")
        }
    }

    await test("#303 Wayne specimen: live RCS omit refuses; SMS needs the flag") {
        let rows: [[String: Any]] = [
            ["is_from_me": 0, "service": "RCS", "handle_id": "+12537920959",
             "chat_guid": "RCS;-;+12537920959", "service_name": "RCS", "participant_count": 1]
        ]
        let target = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+12537920959", declaredThreadService: nil
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: target) == "RCS"
        )
        switch MessagesModule.resolveSendService(requested: nil, liveInboundRaw: "RCS") {
        case .refuse(let reason):
            try expect(reason.contains("omit is inherit-only"))
        case .use:
            throw TestError.assertion("Wayne omit must not become SMS")
        }
        switch MessagesModule.resolveSendService(requested: "SMS", liveInboundRaw: "RCS") {
        case .refuse(let reason):
            try expect(reason.contains("allowSmsDespiteLiveService:true"))
        case .use:
            throw TestError.assertion("Wayne SMS without flag must refuse")
        }
        switch MessagesModule.resolveSendService(
            requested: "SMS", liveInboundRaw: "RCS", allowSmsDespiteLiveService: true
        ) {
        case .use(let service):
            try expect(service == .sms)
        case .refuse(let reason):
            throw TestError.assertion("Wayne SMS + flag must use SMS, got \(reason)")
        }
    }

    await test("#303 Mary specimen: RCS thread identity without inbound still binds RCS") {
        let rows: [[String: Any]] = [
            ["is_from_me": 1, "service": "RCS", "handle_id": "+17575257951",
             "chat_guid": "RCS;-;+17575257951", "service_name": "RCS", "participant_count": 1]
        ]
        let target = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+17575257951", declaredThreadService: nil
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: target) == "RCS",
            "outbound-only RCS thread must still expose RCS identity (54695-class)"
        )
        let prefixed = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+17575257951", declaredThreadService: "RCS"
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: [], target: prefixed) == "RCS",
            "RCS;-;handle with no rows still inherits the named thread"
        )
        switch MessagesModule.resolveSendService(requested: "iMessage", liveInboundRaw: "RCS") {
        case .refuse(let reason):
            try expect(reason.contains("RCS") || reason.contains("silent fallback"))
        case .use:
            throw TestError.assertion("Mary iMessage-into-RCS must fail closed")
        }
    }

    await test("#303 tapbacks and group rows never set 1:1 live service") {
        let rows: [[String: Any]] = [
            ["is_from_me": 0, "service": "iMessage", "handle_id": "+16056013705",
             "chat_guid": "iMessage;-;+16056013705", "associated_message_type": 2,
             "item_type": 0, "participant_count": 1],
            ["is_from_me": 0, "service": "iMessage", "handle_id": "+16056013705",
             "chat_identifier": "chat123456789", "participant_count": 3],
            ["is_from_me": 0, "service": "SMS", "handle_id": "+16056013705",
             "chat_guid": "SMS;-;+16056013705", "service_name": "SMS",
             "associated_message_type": 0, "item_type": 0, "participant_count": 1]
        ]
        let target = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+16056013705", declaredThreadService: nil
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: target) == "SMS",
            "Loved tapback / group inbound must not override the 1:1 SMS thread"
        )
        try expect(
            MessagesModule.latestInboundService(from: rows) == "SMS"
        )
    }

    await test("#303 prefixed chatIdentifier binds that thread, not a sibling inbound") {
        let rows: [[String: Any]] = [
            ["is_from_me": 0, "service": "SMS", "handle_id": "+16056013705",
             "chat_guid": "SMS;-;+16056013705", "service_name": "SMS", "participant_count": 1],
            ["is_from_me": 0, "service": "iMessage", "handle_id": "+16056013705",
             "chat_guid": "iMessage;-;+16056013705", "service_name": "iMessage", "participant_count": 1]
        ]
        let imessageThread = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+16056013705", declaredThreadService: "iMessage"
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: imessageThread) == "iMessage",
            "iMessage;-;handle must not inherit the newer SMS sibling"
        )
        let bare = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+16056013705", declaredThreadService: nil
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: bare) == "SMS",
            "bare handle still inherits latest inbound across 1:1 chats"
        )
    }

    await test("#303 ambiguous iMessage+SMS thread identity without inbound fails closed") {
        let rows: [[String: Any]] = [
            ["is_from_me": 1, "service": "iMessage", "handle_id": "+15551230001",
             "chat_guid": "iMessage;-;+15551230001", "service_name": "iMessage", "participant_count": 1],
            ["is_from_me": 1, "service": "SMS", "handle_id": "+15551230001",
             "chat_guid": "SMS;-;+15551230001", "service_name": "SMS", "participant_count": 1]
        ]
        let target = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "+15551230001", declaredThreadService: nil
        )
        try expect(MessagesProtocolDiscriminator.liveService(from: rows, target: target) == nil)
        try expect(MessagesProtocolDiscriminator.isAmbiguousThreadIdentity(from: rows, handle: "+15551230001"))
        guard case .object(let fields) = MessagesModule.sendClosedEnvelope(
            error: MessagesProtocolDiscriminator.ambiguousThreadsRefuseReason(handle: "+15551230001")
        ) else {
            throw TestError.assertion("closed envelope must be an object")
        }
        try expect(fields["sent"] == .bool(false))
        try expect(fields["deliveryInvoked"] == .bool(false))
        guard case .string(let reason)? = fields["error"] else {
            throw TestError.assertion("ambiguous refuse must name a reason")
        }
        try expect(reason.contains("cannot inherit a single live 1:1 service"))
    }

    await test("#303 canonical handle match: national digits bind E.164 thread") {
        let rows: [[String: Any]] = [
            ["is_from_me": 0, "service": "iMessage", "handle_id": "+16056013705",
             "chat_guid": "iMessage;-;+16056013705", "service_name": "iMessage", "participant_count": 1]
        ]
        let target = MessagesProtocolDiscriminator.Target.oneToOne(
            handle: "605-601-3705", declaredThreadService: nil
        )
        try expect(
            MessagesProtocolDiscriminator.liveService(from: rows, target: target) == "iMessage"
        )
    }

    await test("#303 specimen resolve matrix is fail-closed with no silent remap") {
        let cases: [(String?, String?, Bool, Bool)] = [
            (nil, "iMessage", false, true),
            (nil, "SMS", false, true),
            (nil, "RCS", false, false),
            (nil, "unknown", false, false),
            (nil, nil, false, false),
            ("SMS", "iMessage", false, false),
            ("iMessage", "SMS", false, false),
            ("SMS", "RCS", false, false),
            ("SMS", "RCS", true, true),
            ("SMS", "iMessage", true, false),
            ("iMessage", "RCS", true, false),
            ("RCS", nil, false, false),
            ("auto", "iMessage", false, false)
        ]
        for (requested, live, flag, shouldUse) in cases {
            switch MessagesModule.resolveSendService(
                requested: requested,
                liveInboundRaw: live,
                allowSmsDespiteLiveService: flag
            ) {
            case .use:
                try expect(shouldUse, "expected refuse for requested=\(requested ?? "omit") live=\(live ?? "none") flag=\(flag)")
            case .refuse:
                try expect(!shouldUse, "expected use for requested=\(requested ?? "omit") live=\(live ?? "none") flag=\(flag)")
            }
        }
    }

    await test("#303 1:1 chatIdentifier uses discriminator, not first-match AppleScript") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsURL
            .deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Modules/MessagesModule.swift"), encoding: .utf8)
        try expect(source.contains("MessagesProtocolDiscriminator.parseChatIdentifier"),
                   "1:1 chatIdentifier must parse through the discriminator")
        try expect(source.contains("ordinaryOneToOneSendValue"),
                   "1:1 chatIdentifier must share the recipient send path")
        let groupScriptRange = source.range(of: "repeat with targetService in services")
        let discriminatorRange = source.range(of: "case .oneToOne(let handle, let declared):")
        try expect(groupScriptRange != nil, "group existing-chat script remains")
        try expect(discriminatorRange != nil)
        if let discriminatorRange, let groupScriptRange {
            try expect(
                discriminatorRange.lowerBound < groupScriptRange.lowerBound,
                "1:1 bind must run before the group first-match script"
            )
        }
        try expect(!source.contains("h.id LIKE '%'"))
        try expect(!source.contains("c.chat_identifier LIKE '%'"))
    }

    await test("#303 messages_send catalog documents thread inherit and 1:1 chatIdentifier") {
        let router = ToolRouter(
            securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
            auditLog: AuditLog()
        )
        await MessagesModule.register(on: router)
        let send = await router.registrations(forModule: "messages").first { $0.name == "messages_send" }!
        try expect(send.description.contains("chat.guid")
                   || send.description.contains("thread/contact"),
                   "catalog must name thread-identity inherit")
        try expect(send.description.contains("1:1 chatIdentifier")
                   || send.description.contains("any;-;"),
                   "catalog must say 1:1 chatIdentifier uses the discriminator")
        try expect(send.description.contains("allowSmsDespiteLiveService"))
        try expect(send.description.localizedCaseInsensitiveContains("fail closed")
                   || send.description.contains("Fail closed"))
        try expect(send.description.contains("Does not change host Auto-review"))
    }

    await test("#303 protocol discriminator doc is the operator contract") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let doc = try String(contentsOf: testsURL
            .deletingLastPathComponent()
            .appendingPathComponent("docs/operator/messages-protocol-discriminator.md"), encoding: .utf8)
        try expect(doc.contains("#303"))
        try expect(doc.contains("#301"))
        try expect(doc.contains("54580"), "Veronica inbound ROWID")
        try expect(doc.contains("54506"), "Wayne RCS inbound ROWID")
        try expect(doc.contains("54695"), "Mary local row")
        try expect(doc.contains("allowSmsDespiteLiveService"))
        try expect(doc.contains("LIVE matrix"))
        try expect(doc.contains("#302"), "must point false failed-to-send at the sibling")
        try expect(!doc.contains("LIKE '%'"))
    }

    await test("#303 lookup SQL uses exact IN slots and tapback/1:1 filters") {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsURL
            .deletingLastPathComponent()
            .appendingPathComponent("TheBridge/Modules/MessagesModule.swift"), encoding: .utf8)
        try expect(source.contains("lookupLiveThreadRows"))
        try expect(source.contains("MessagesQueryContracts.normalRowPredicate"))
        try expect(source.contains("chat_handle_join"))
        try expect(source.contains("paddedLookupKeys"))
        try expect(!source.contains("h.id LIKE '%' ||"))
    }
}
