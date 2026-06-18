#!/usr/bin/env python3
"""Rewrite all 66 The Bridge MCP tool descriptions in Swift source files."""
import os

BASE = "os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'TheBridge')"

# (relative_path, old_desc_substring, new_full_description_value)
# We match on unique substrings to avoid escaping issues
R = []

# === ServerManager.swift (1) ===
R.append(("Server/ServerManager.swift",
    "Echoes back the input message. Useful for connectivity testing.",
    "Echoes back the input message unchanged. Returns {message: string}. Use to verify MCP connectivity."))

# === NotionModule.swift (16) ===
R.append(("Modules/NotionModule.swift",
    "Search the Notion workspace for pages and databases by query. Returns matching results with titles and URLs. Requires NOTION_API_TOKEN.",
    "Search the Notion workspace for pages and databases by text query. Returns an array of {id, title, url, object_type} matches. Requires a configured NOTION_API_TOKEN."))
R.append(("Modules/NotionModule.swift",
    "Read a Notion page's properties and child blocks by page ID. Returns page metadata and content blocks.",
    "Read a Notion page's properties and optionally its child blocks. Returns {properties, blocks[]} with block types, content, and nesting. Set includeBlocks=false to fetch only properties."))
R.append(("Modules/NotionModule.swift",
    "Update a Notion page's properties. Accepts a JSON string of property updates. SecurityGate enforces orange-tier confirmation.",
    "Update a Notion page's properties. Pass a JSON string of Notion API property objects. Returns the updated page object. Requires user confirmation before execution."))
R.append(("Modules/NotionModule.swift",
    "Create a new Notion page under a parent page or database. Returns the created page ID and URL.",
    "Create a new Notion page under a parent page or database. Pass properties as a JSON string; optionally include children blocks. Returns {id, url} of the created page."))
R.append(("Modules/NotionModule.swift",
    "Query a Notion data source with optional filter and sort. Returns matching pages.",
    "Query a Notion database with optional filter, sort, and pagination. Returns {results[], has_more, next_cursor}. Filter and sorts must be JSON strings in Notion API format."))
R.append(("Modules/NotionModule.swift",
    "Append child blocks to a page or block. Supports position control (after specific block).",
    "Append child blocks to a Notion page or block. Pass children as a JSON string array of block objects. Use afterBlock to insert after a specific block ID. Returns the appended blocks."))
R.append(("Modules/NotionModule.swift",
    "Delete (trash) a Notion block by ID.",
    "Move a Notion block to trash by its ID. Returns confirmation. Deletion is reversible from the Notion UI."))
R.append(("Modules/NotionModule.swift",
    "Get page content as markdown. Returns the page body in markdown format.",
    "Read a Notion page body as markdown. Returns {markdown: string}. Faster than notion_page_read when you only need content, not properties or block structure."))
R.append(("Modules/NotionModule.swift",
    "Update page content from markdown. Replaces the page body with the provided markdown.",
    "Overwrite a Notion page body with new markdown -- this is a full replacement, existing content is deleted first. Returns confirmation. Use notion_blocks_append for non-destructive additions."))
R.append(("Modules/NotionModule.swift",
    "List comments on a Notion page or block.",
    "List comments on a Notion page or block. Returns an array of {id, text, author, created_time} comments, newest first. Accepts pageSize for pagination."))
R.append(("Modules/NotionModule.swift",
    "Create a comment on a Notion page.",
    "Create a page-level comment on a Notion page. Returns the created comment object with id and timestamp."))
R.append(("Modules/NotionModule.swift",
    "List all users in the Notion workspace.",
    "List all users in the Notion workspace. Returns an array of {id, name, email, type, avatar_url} entries. Supports pageSize for pagination."))
R.append(("Modules/NotionModule.swift",
    "Move a Notion page to a new parent page or database.",
    "Move a Notion page to a new parent (page or database). Specify parentType as 'page_id' or 'database_id'. Returns the updated page object."))
R.append(("Modules/NotionModule.swift",
    "Upload a local file to Notion (single-part, max 20MB). Returns the file upload object.",
    "Upload a local file to Notion file storage (single-part, max 20 MB). Returns the file upload object with a URL usable in page content or properties."))
R.append(("Modules/NotionModule.swift",
    "Introspect the current Notion API token. Returns token info including bot details and workspace.",
    "Introspect the active Notion API token. Returns {bot, owner, workspace} metadata. Use to verify which integration and workspace are connected."))
R.append(("Modules/NotionModule.swift",
    "List all configured Notion workspace connections with health status.",
    "List all configured Notion workspace connections. Returns an array of {name, workspace, status} entries showing connection health."))

# === FileModule.swift (12) ===
R.append(("Modules/FileModule.swift",
    "List contents of a directory. Supports recursive listing and showing hidden files.",
    "List directory contents. Returns an array of {name, type, size} entries. Set recursive=true for deep listing, showHidden=true to include dotfiles."))
R.append(("Modules/FileModule.swift",
    "Search for files whose names contain the query string within a directory.",
    "Search for files by name substring within a directory tree. Returns an array of matching absolute file paths."))
R.append(("Modules/FileModule.swift",
    "Get metadata (size, created, modified, type) for a file or directory.",
    "Get metadata for a file or directory. Returns {size, created, modified, type, permissions}. Use before file_read to check size or existence."))
R.append(("Modules/FileModule.swift",
    "Read text content from a file. Supports encoding and maxBytes parameters.",
    "Read text content from a file. Returns {content, bytesRead}. Use maxBytes to cap large files; set encoding to 'ascii' or 'latin1' for non-UTF-8 files."))
R.append(("Modules/FileModule.swift",
    "Write text content to a file. Supports createDirs for automatic parent directory creation.",
    "Write text content to a file, creating or overwriting it. Set createDirs=true to auto-create parent directories. Returns {bytesWritten, path}."))
R.append(("Modules/FileModule.swift",
    "Append text content to an existing file.",
    "Append text to the end of an existing file without overwriting. Returns {bytesWritten}. File must already exist -- use file_write for new files."))
R.append(("Modules/FileModule.swift",
    "Move a file or directory to a new location.",
    "Move a file or directory to a new absolute path. Returns the new path on success. Works across volumes."))
R.append(("Modules/FileModule.swift",
    "Rename a file or directory in place.",
    "Rename a file or directory in its current location. Pass the new name (not a full path). Returns the updated absolute path."))
R.append(("Modules/FileModule.swift",
    "Copy a file or directory to a new location.",
    "Copy a file or directory to a new absolute path. Returns the destination path on success. Copies directories recursively."))
R.append(("Modules/FileModule.swift",
    "Create a new directory with intermediate directories.",
    "Create a directory, including any missing intermediate parents (like mkdir -p). Returns the created path."))
R.append(("Modules/FileModule.swift",
    "Read text content from the system clipboard (pasteboard).",
    "Read the current text content from the macOS system clipboard. Returns {content: string} or null if the clipboard is empty or non-text."))
R.append(("Modules/FileModule.swift",
    "Write text content to the system clipboard (pasteboard).",
    "Write text to the macOS system clipboard, replacing any existing content. Returns confirmation."))

# === SkillsModule.swift (2) ===
R.append(("Modules/SkillsModule.swift",
    "Fetch a named skill (Notion page) by name. Returns the page title, properties, and block content as text. Skills are configured in Settings",
    "Fetch a named skill by name (case-insensitive). Returns {title, properties, blocks} from the linked Notion page. Results cached 10 minutes. Configure skills in Settings"))
R.append(("Modules/SkillsModule.swift",
    "Manage The Bridge skills configuration. Actions: list, add, delete, toggle, rename, update_url, bulk_add. Skills are persisted in Settings",
    "Manage the skills registry. Supported actions: list, add, delete, toggle, rename, update_url, bulk_add. Returns the updated skills list. Skills persist in Settings"))

# === ChromeModule.swift (5) ===
R.append(("Modules/ChromeModule.swift",
    "List all open tabs in Google Chrome. Returns tab title, URL, window ID, and tab index for every open tab across all windows.",
    "List all open Chrome tabs across all windows. Returns an array of {title, url, windowId, tabIndex} per tab. Use windowId + tabIndex to target a tab in other chrome_* tools."))
R.append(("Modules/ChromeModule.swift",
    "Navigate a Chrome tab to a URL, or open a new tab. If windowId and tabIndex are omitted, navigates the active tab of the front window. Set newTab to true to open a new tab instead.",
    "Navigate a Chrome tab to a URL, or open a new tab. Omit windowId/tabIndex to target the active tab of the front window. Set newTab=true to open in a new tab instead. Returns the final URL."))
R.append(("Modules/ChromeModule.swift",
    "Extract page content from a Chrome tab via JavaScript. By default returns document.body.innerText. Optionally pass a CSS selector to target a specific element, or set mode to 'html' for full HTML.",
    "Extract page content from a Chrome tab. Returns innerText by default. Use selector to target a specific element, mode='html' for raw HTML. Prefer over chrome_execute_js for simple content reads."))
R.append(("Modules/ChromeModule.swift",
    "Execute arbitrary JavaScript in a Chrome tab and return the result. Use for dynamic page interaction, form filling, DOM manipulation, etc.",
    "Execute arbitrary JavaScript in a Chrome tab and return the result as a string. Use for DOM manipulation, form filling, or dynamic interaction. Prefer chrome_read_page for simple content extraction."))
R.append(("Modules/ChromeModule.swift",
    "Capture the visible content of a Chrome tab as a PNG. Uses AppleScript for Chrome window bounds and macOS screencapture for the region. When windowId and tabIndex are provided, activates that tab first. Returns the file path and dimensions.",
    "Capture the visible Chrome tab as a PNG screenshot. When windowId/tabIndex are provided, activates that tab first. Returns {filePath, width, height}. Use screen_capture for non-Chrome windows."))

# === CredentialModule.swift (4) ===
R.append(("Modules/CredentialModule.swift",
    "Store or update a credential in the macOS Keychain. Supports password and card types. Card credentials are tokenized via Stripe before storage",
    "Store or update a credential in the macOS Keychain. Supports 'password' and 'card' types -- cards are Stripe-tokenized before storage, raw numbers never persist. Triggers Touch ID prompt. Returns confirmation."))
R.append(("Modules/CredentialModule.swift",
    "Retrieve a stored credential by service and account. Returns the password or token along with type and metadata. No biometric required",
    "Retrieve a stored credential by service + account key. Returns {password, type, metadata}. No biometric prompt -- SecurityGate approval is sufficient."))
R.append(("Modules/CredentialModule.swift",
    "List stored credentials (metadata only",
    "List stored credentials (metadata only -- no secrets exposed). Returns an array of {service, account, type, metadata} entries. Filter by type or service substring."))
R.append(("Modules/CredentialModule.swift",
    "Remove a stored credential from the macOS Keychain. Requires biometric (Touch ID) authentication before deletion.",
    "Remove a credential from the macOS Keychain by service + account key. Triggers Touch ID prompt before deletion. Returns confirmation."))

# === SessionModule.swift (3) ===
R.append(("Modules/SessionModule.swift",
    "Returns the live tool registry. Lists all registered tools with their name, module, tier, description, and input schema. Supports optional module filter.",
    "List all registered tools in the live registry. Returns an array of {name, module, tier, description, inputSchema} per tool. Use the module parameter to filter by module name."))
R.append(("Modules/SessionModule.swift",
    "Returns session information: uptime, connections, toolCalls (from audit log), activeClients, and auditLogSize.",
    "Get current session diagnostics. Returns {uptime, connections, toolCalls, activeClients, auditLogSize}. Use to monitor bridge health and activity."))
R.append(("Modules/SessionModule.swift",
    "Clear session state (audit log entries). Requires confirm: true parameter. Returns previous uptime and audit log size before clearing.",
    "Clear session audit log entries. Requires confirm=true or the call is rejected. Returns the previous {uptime, auditLogSize} before clearing."))

# === ScreenRecording.swift (2) ===
R.append(("Modules/ScreenRecording.swift",
    "Begin screen recording via SCStream + AVAssetWriter. Returns output file path. Safety cap default 60s (max 300s). Only one recording at a time.",
    "Start a screen recording (SCStream + AVAssetWriter). Returns the output file path immediately. Default safety cap is 60s (max 300s). Only one recording at a time -- call screen_record_stop to finish."))
R.append(("Modules/ScreenRecording.swift",
    "Stop the active screen recording. Returns file path, duration in seconds, and file size in bytes.",
    "Stop the active screen recording. Returns {filePath, duration, fileSize}. Fails if no recording is in progress."))

# === SystemModule.swift (4) ===
R.append(("Modules/SystemModule.swift",
    "Returns macOS system information: OS version, hardware model, CPU, memory, hostname, and uptime.",
    "Get macOS system info. Returns {osVersion, model, cpu, memory, hostname, uptime}. Use for environment diagnostics."))
R.append(("Modules/SystemModule.swift",
    "List running processes. Supports optional filter by name and limit on results. Returns PID, name, CPU%, MEM%, and user.",
    "List running macOS processes. Returns an array of {pid, name, cpu, mem, user} sorted by sortBy (default: cpu). Use filter for name substring matching."))
R.append(("Modules/SystemModule.swift",
    "Send a local macOS notification via UNUserNotificationCenter. Displays a system notification with title and body text.",
    "Send a local macOS notification banner. Returns confirmation. Optionally specify a sound name (e.g. 'Glass', 'Ping')."))
R.append(("Modules/SystemModule.swift",
    "Search for contacts by name, phone, or email. Returns matching contacts with name, phone numbers, email addresses, and postal addresses. Uses CNContactStore (Contacts.framework).",
    "Search macOS Contacts by name, phone, or email. Returns matching contacts with name, phones, emails, and addresses. Specify fields to control which fields are searched (default: name only)."))

# === MessagesModule.swift (6) ===
R.append(("Modules/MessagesModule.swift",
    "Search iMessage/SMS messages by keyword. Returns matching messages with sender, date, and chat context. Uses native SQLite on chat.db (read-only).",
    "Search iMessage/SMS messages by keyword. Returns matching messages with sender, date, text, and chat context. Read-only query on chat.db."))
R.append(("Modules/MessagesModule.swift",
    "List recent conversations with last message preview, ordered by recency.",
    "List recent iMessage/SMS conversations ordered by recency. Returns an array of {chatIdentifier, lastMessage, date} previews. Use limit to cap results."))
R.append(("Modules/MessagesModule.swift",
    "Get message thread with a specific contact (phone number or email).",
    "Get the message thread with a specific contact (phone number or email). Returns messages in chronological order with sender, text, and date. Use limit to cap results."))
R.append(("Modules/MessagesModule.swift",
    "Get a single message by its ROWID with full metadata.",
    "Get a single message by its ROWID. Returns full metadata including text, sender, date, attachments, and read status."))
R.append(("Modules/MessagesModule.swift",
    "List participants (handles) in a chat identified by chat_identifier.",
    "List participants in a chat by chat_identifier. Returns an array of handles (phone numbers or emails) in the conversation."))
R.append(("Modules/MessagesModule.swift",
    "Send an iMessage or SMS/RCS message via AppleScript. Auto-detects service type from chat history. Requires explicit confirm='SEND' parameter.",
    "Send an iMessage or SMS/RCS message. Auto-detects service type from chat history. You must pass confirm='SEND' (exact string) or the call is rejected. Returns confirmation with message details."))

# === ShellModule.swift (2) ===
R.append(("Modules/ShellModule.swift",
    "Execute a shell command with optional timeout and working directory. Returns stdout, stderr, exit code, and duration in seconds. SecurityGate enforces auto-escalation patterns and forbidden path restrictions.",
    "Execute a shell command with optional timeout and working directory. Returns {stdout, stderr, exitCode, duration}. Commands matching auto-escalation patterns (e.g. sudo, rm -rf) require elevated confirmation."))
R.append(("Modules/ShellModule.swift",
    "Execute a pre-approved script from the scripts directory. Only scripts listed in the approved scripts file can run. Returns stdout, stderr, and exit code.",
    "Execute a pre-approved script from the scripts directory. Only scripts in the approved list are allowed. Returns {stdout, stderr, exitCode}."))

# === AppleScriptModule.swift (1) ===
R.append(("Modules/AppleScriptModule.swift",
    "Execute AppleScript code in-process via NSAppleScript. Avoids TCC re-prompting by running as TheBridge.app (not /usr/bin/osascript). Use for controlling apps (Chrome, Finder, System Events, etc.). Returns the result string or error info.",
    "Execute AppleScript in-process via NSAppleScript. Runs as TheBridge.app to avoid TCC re-prompting (unlike /usr/bin/osascript). Returns the result string or error info. Use for controlling apps like Chrome, Finder, System Events."))

# === ScreenModule.swift (2) ===
R.append(("Modules/ScreenModule.swift",
    "Capture a screenshot of the display, a specific window, or a region. Returns the file path, dimensions, and file size. Uses ScreenCaptureKit (requires Screen Recording permission).",
    "Capture a screenshot of a display, window, or region. Returns {filePath, width, height, fileSize}. Targets: 'display' (default), 'window' (requires windowId), 'region' (requires {x,y,w,h}), 'all_displays'."))
R.append(("Modules/ScreenModule.swift",
    "Capture the screen and extract text via OCR (Vision framework). Returns recognized text with confidence scores and bounding boxes. Uses ScreenCaptureKit for capture + VNRecognizeTextRequest for text recognition.",
    "Capture the screen and extract text via OCR (Vision framework). Returns recognized text with confidence scores and bounding boxes. Same target options as screen_capture. Default language is English."))

# === PaymentModule.swift (1) ===
R.append(("Modules/PaymentModule.swift",
    "Execute a Stripe payment intent using a stored payment method credential (pm_ token). Requires explicit approval and biometric authentication.",
    "Execute a Stripe payment using a stored pm_ token from credential_save. Requires user approval + Touch ID. Pass amount in cents (e.g. 2500 = $25). Returns the PaymentIntent object. Always provide an idempotency_key."))

# === AccessibilityModule.swift (5) ===
R.append(("Modules/AccessibilityModule.swift",
    "Return the frontmost application's name, bundleId, PID, and focused UI element.",
    "Get the frontmost application info. Returns {name, bundleId, pid, focusedElement}. Use the returned pid in other ax_* tools to target this app."))
R.append(("Modules/AccessibilityModule.swift",
    "Dump the AX element hierarchy for an app. Specify PID or omit for frontmost. Configurable depth (default 5) and format (tree or flat).",
    "Dump the accessibility element hierarchy for an app. Returns a nested tree or flat array of UI elements. Omit pid to target the frontmost app. Use maxDepth to limit traversal depth."))
R.append(("Modules/AccessibilityModule.swift",
    "Search the AX tree for elements matching role, title, and/or label. Returns matching elements with paths, positions, and sizes.",
    "Search the AX tree for elements matching role, title, and/or label (case-insensitive substrings). Returns matches with paths, positions, and sizes. Use the returned path in ax_perform_action."))
R.append(("Modules/AccessibilityModule.swift",
    "Deep inspect a single AX element. Find by path, or by role/title. Returns all attributes, actions, position, size, and state.",
    "Deep-inspect a single AX element by path, role, or title. Returns all attributes, available actions, position, size, and state. Use after ax_find_element to get full element details."))
R.append(("Modules/AccessibilityModule.swift",
    "Perform an action on an AX element: press a button, set a value, focus, confirm, cancel, increment, or decrement. Accepts friendly names or raw AX action strings.",
    "Perform an action on an AX element (press, focus, setValue, confirm, cancel, increment, decrement). Locate by path or role+title. For setValue, include the value parameter. Returns confirmation."))


# === EXECUTION ===
def main():
    by_file = {}
    for rel_path, old_sub, new_desc in R:
        full = os.path.join(BASE, rel_path)
        by_file.setdefault(full, []).append((old_sub, new_desc))

    total_ok = 0
    total_miss = 0

    for filepath, pairs in sorted(by_file.items()):
        with open(filepath, 'r') as f:
            content = f.read()

        for old_sub, new_desc in pairs:
            # Find the line containing this old substring
            idx = content.find(old_sub)
            if idx == -1:
                total_miss += 1
                print(f"MISS in {os.path.basename(filepath)}: {old_sub[:60]}...")
                continue

            # Find the full description: "..." on this line
            # Walk backward to find opening quote after 'description: '
            line_start = content.rfind('\n', 0, idx) + 1
            desc_marker = content.find('description: "', line_start)
            if desc_marker == -1:
                total_miss += 1
                print(f"NO MARKER in {os.path.basename(filepath)}: {old_sub[:60]}...")
                continue

            quote_start = content.index('"', desc_marker)
            # Find matching closing quote (handle escaped quotes)
            i = quote_start + 1
            while i < len(content):
                if content[i] == '\\':
                    i += 2
                    continue
                if content[i] == '"':
                    break
                i += 1
            quote_end = i

            old_full = content[quote_start:quote_end+1]
            new_full = '"' + new_desc + '"'
            content = content[:quote_start] + new_full + content[quote_end+1:]
            total_ok += 1

        with open(filepath, 'w') as f:
            f.write(content)

    print(f"\nDone: {total_ok} replaced, {total_miss} missed, {len(R)} total entries")
    print(f"Files modified: {len(by_file)}")

if __name__ == "__main__":
    main()
