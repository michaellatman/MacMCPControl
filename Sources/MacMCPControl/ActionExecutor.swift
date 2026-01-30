import Foundation
import CoreGraphics
import AppKit

enum ActionError: Error {
    case invalidAction(String)
    case invalidParameters(String)
    case executionFailed(String)
}

extension ActionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidAction(let message):
            return message
        case .invalidParameters(let message):
            return message
        case .executionFailed(let message):
            return message
        }
    }
}

class ActionExecutor {
    private let screenshotWidth: CGFloat = 1280
    private let screenshotHeight: CGFloat = 800

    private struct RenderMapping {
        let frame: CGRect
        let scale: CGFloat
        let padX: CGFloat
        let padY: CGFloat
    }

    private func computeMapping(screen: NSScreen) -> RenderMapping {
        let frame = screen.frame
        let scale = min(screenshotWidth / frame.width, screenshotHeight / frame.height)
        let padX = (screenshotWidth - (frame.width * scale)) / 2
        let padY = (screenshotHeight - (frame.height * scale)) / 2
        return RenderMapping(frame: frame, scale: scale, padX: padX, padY: padY)
    }
    func execute(actionType: String, params: [String: Any]) throws -> [String: Any] {
        // Check accessibility permissions for actions that require them
        let actionsRequiringAccessibility = ["mouse_move", "left_click", "left_click_drag", "right_click", "middle_click", "double_click", "key", "type", "scroll"]

        if actionsRequiringAccessibility.contains(actionType) {
            if !AccessibilityPermissions.isAccessibilityEnabled() {
                throw ActionError.executionFailed("Accessibility permissions not granted. Please enable in System Preferences > Security & Privacy > Privacy > Accessibility")
            }
        }

        print("➤ Executing action: \(actionType)")

        switch actionType {
        case "mouse_move":
            return try executeMouseMove(params: params)
        case "left_click":
            return try executeLeftClick(params: params)
        case "left_click_drag":
            return try executeLeftClickDrag(params: params)
        case "right_click":
            return try executeRightClick(params: params)
        case "middle_click":
            return try executeMiddleClick(params: params)
        case "double_click":
            return try executeDoubleClick(params: params)
        case "screenshot":
            return try executeScreenshot(params: params)
        case "key":
            return try executeKey(params: params)
        case "type":
            return try executeType(params: params)
        case "cursor_position":
            return try executeCursorPosition()
        case "wait":
            return try executeWait(params: params)
        case "shell":
            return try executeShell(params: params)
        case "applescript":
            return try executeAppleScript(params: params)
        case "scroll":
            return try executeScroll(params: params)
        default:
            throw ActionError.invalidAction("Unknown action: \(actionType)")
        }
    }

    private func executeMouseMove(params: [String: Any]) throws -> [String: Any] {
        guard let x = params["coordinate"] as? [Int], x.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let point = try convertToEventPoint(coordinate: x)
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)

        return ["success": true]
    }

    private func executeLeftClick(params: [String: Any]) throws -> [String: Any] {
        guard let coordinate = params["coordinate"] as? [Int], coordinate.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let point = try convertToEventPoint(coordinate: coordinate)

        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        mouseDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp?.post(tap: .cghidEventTap)

        return ["success": true]
    }

    private func executeLeftClickDrag(params: [String: Any]) throws -> [String: Any] {
        guard let coordinate = params["coordinate"] as? [Int], coordinate.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let currentPoint = CGEvent(source: nil)?.location ?? .zero
        let targetPoint = try convertToEventPoint(coordinate: coordinate)

        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentPoint, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: 0.05)

        let mouseDrag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left)
        mouseDrag?.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: 0.05)

        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left)
        mouseUp?.post(tap: .cghidEventTap)

        return ["success": true]
    }

    private func executeRightClick(params: [String: Any]) throws -> [String: Any] {
        guard let coordinate = params["coordinate"] as? [Int], coordinate.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let point = try convertToEventPoint(coordinate: coordinate)

        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)

        mouseDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp?.post(tap: .cghidEventTap)

        return ["success": true]
    }

    private func executeMiddleClick(params: [String: Any]) throws -> [String: Any] {
        guard let coordinate = params["coordinate"] as? [Int], coordinate.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let point = try convertToEventPoint(coordinate: coordinate)

        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: point, mouseButton: .center)

        mouseDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        mouseUp?.post(tap: .cghidEventTap)

        return ["success": true]
    }

    private func executeDoubleClick(params: [String: Any]) throws -> [String: Any] {
        guard let coordinate = params["coordinate"] as? [Int], coordinate.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let point = try convertToEventPoint(coordinate: coordinate)

        for _ in 0..<2 {
            let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

            mouseDown?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.05)
            mouseUp?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.1)
        }

        return ["success": true]
    }

    private func executeScreenshot(params: [String: Any]) throws -> [String: Any] {
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID? else {
            throw ActionError.executionFailed("Failed to get main display")
        }

        guard let image = CGDisplayCreateImage(displayID) else {
            throw ActionError.executionFailed("Failed to capture screenshot")
        }

        guard let screen = NSScreen.main else {
            throw ActionError.executionFailed("Failed to get main screen")
        }

        let backingScale = screen.backingScaleFactor
        let resizedImage: CGImage
        if backingScale > 1 {
            let targetWidth = max(1, Int(CGFloat(image.width) / backingScale))
            let targetHeight = max(1, Int(CGFloat(image.height) / backingScale))
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: image.bitsPerComponent,
                bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: image.bitmapInfo.rawValue
            ) else {
                throw ActionError.executionFailed("Failed to resize screenshot")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let outputImage = context.makeImage() else {
                throw ActionError.executionFailed("Failed to resize screenshot")
            }
            resizedImage = outputImage
        } else {
            resizedImage = image
        }

        let mapping = computeMapping(screen: screen)
        let fullImage = NSImage(cgImage: resizedImage, size: mapping.frame.size)
        guard let fullCGImage = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ActionError.executionFailed("Failed to render full screenshot")
        }

        let targetWidth = Int(screenshotWidth)
        let targetHeight = Int(screenshotHeight)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ActionError.executionFailed("Failed to scale screenshot")
        }

        context.interpolationQuality = .high
        let renderScale = mapping.scale
        let padX = mapping.padX
        let padY = mapping.padY
        let scaledWidth = mapping.frame.width * renderScale
        let scaledHeight = mapping.frame.height * renderScale
        context.draw(
            fullCGImage,
            in: CGRect(x: padX, y: padY, width: scaledWidth, height: scaledHeight)
        )

        guard let scaledCGImage = context.makeImage() else {
            throw ActionError.executionFailed("Failed to scale screenshot")
        }

        let bitmapRep = NSBitmapImageRep(cgImage: scaledCGImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw ActionError.executionFailed("Failed to encode screenshot as PNG")
        }

        let base64String = pngData.base64EncodedString()

        return [
            "success": true,
            "base64_image": base64String
        ]
    }

    private func executeKey(params: [String: Any]) throws -> [String: Any] {
        let rawKeys = params["keys"] as? [String]
        let textKey = params["text"] as? String
        let keys = rawKeys ?? (textKey.map { [$0] } ?? [])
        if keys.isEmpty {
            throw ActionError.invalidParameters("Missing keys parameter")
        }

        let modifierKeyCodes = try keys
            .filter { isModifierKey($0) }
            .map { try mapKeyToCode($0) }
        let nonModifierKeys = keys.filter { !isModifierKey($0) }

        for keyCode in modifierKeyCodes {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
            keyDown?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }

        if nonModifierKeys.isEmpty {
            for keyCode in modifierKeyCodes.reversed() {
                let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
                keyUp?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.01)
            }
            return ["success": true]
        }

        for key in nonModifierKeys {
            let keyCode = try mapKeyToCode(key)
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            keyUp?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }

        for keyCode in modifierKeyCodes.reversed() {
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }

        return ["success": true]
    }

    private func executeType(params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw ActionError.invalidParameters("Missing text parameter")
        }

        for char in text {
            let utf16Values = Array(String(char).utf16)
            utf16Values.withUnsafeBufferPointer { buffer in
                let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                keyDown?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                keyUp?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                keyDown?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.01)
                keyUp?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        return ["success": true]
    }

    private func executeCursorPosition() throws -> [String: Any] {
        guard let screen = NSScreen.main else {
            throw ActionError.executionFailed("Failed to get main screen")
        }
        let mouseLocation = NSEvent.mouseLocation
        let mapping = computeMapping(screen: screen)
        let screenTopLeftX = mouseLocation.x - mapping.frame.minX
        let screenTopLeftY = mapping.frame.maxY - mouseLocation.y
        let x = Int(round(mapping.padX + (screenTopLeftX * mapping.scale)))
        let y = Int(round(mapping.padY + (screenTopLeftY * mapping.scale)))

        return [
            "success": true,
            "x": x,
            "y": y
        ]
    }

    private func executeWait(params: [String: Any]) throws -> [String: Any] {
        guard let duration = params["duration"] as? Double else {
            throw ActionError.invalidParameters("Missing duration parameter")
        }
        if duration < 0 {
            throw ActionError.invalidParameters("Duration must be non-negative")
        }
        Thread.sleep(forTimeInterval: duration)
        return ["success": true]
    }

    private func mapKeyToCode(_ key: String) throws -> CGKeyCode {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.count == 1, let char = normalized.first, let keyCode = mapCharToKeyCode(char) {
            return keyCode
        }

        let keyMap: [String: CGKeyCode] = [
            "enter": 0x24,
            "tab": 0x30,
            "space": 0x31,
            "backspace": 0x33,
            "escape": 0x35,
            "capslock": 0x39,
            "shift": 0x38,
            "control": 0x3B,
            "alt": 0x3A,
            "meta": 0x37,
            "super": 0x37,
            "delete": 0x75,
            "home": 0x73,
            "end": 0x77,
            "pageup": 0x74,
            "pagedown": 0x79,
            "arrowleft": 0x7B,
            "arrowright": 0x7C,
            "arrowdown": 0x7D,
            "arrowup": 0x7E,
            "f1": 0x7A,
            "f2": 0x78,
            "f3": 0x63,
            "f4": 0x76,
            "f5": 0x60,
            "f6": 0x61,
            "f7": 0x62,
            "f8": 0x64,
            "f9": 0x65,
            "f10": 0x6D,
            "f11": 0x67,
            "f12": 0x6F
        ]

        guard let keyCode = keyMap[normalized] else {
            throw ActionError.invalidParameters("Unknown key: \(key)")
        }

        return keyCode
    }

    private func isModifierKey(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "shift"
            || normalized == "control"
            || normalized == "alt"
            || normalized == "meta"
            || normalized == "super"
    }

    private func mapCharToKeyCode(_ char: Character) -> CGKeyCode? {
        let charMap: [Character: CGKeyCode] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
            "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
            "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
            "4": 0x15, "5": 0x17, "6": 0x16, "=": 0x18, "9": 0x19,
            "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
            "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
            "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
            ".": 0x2F, " ": 0x31
        ]

        return charMap[char]
    }

    private func executeShell(params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw ActionError.invalidParameters("Missing command parameter")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            return [
                "success": task.terminationStatus == 0,
                "exitCode": task.terminationStatus,
                "stdout": output,
                "stderr": errorOutput
            ]
        } catch {
            throw ActionError.executionFailed("Failed to execute command: \(error.localizedDescription)")
        }
    }

    private func executeAppleScript(params: [String: Any]) throws -> [String: Any] {
        guard let script = params["script"] as? String else {
            throw ActionError.invalidParameters("Missing script parameter")
        }

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let output = appleScript?.executeAndReturnError(&error)

        if let error = error {
            let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
            throw ActionError.executionFailed("AppleScript execution failed: \(errorMessage)")
        }

        let result = output?.stringValue ?? ""
        return [
            "success": true,
            "result": result
        ]
    }

    private func executeScroll(params: [String: Any]) throws -> [String: Any] {
        guard let coordinate = params["coordinate"] as? [Int], coordinate.count == 2 else {
            throw ActionError.invalidParameters("Missing or invalid coordinate")
        }

        let direction = params["direction"] as? String ?? "down"
        let amount = params["amount"] as? Int ?? 1

        let point = try convertToEventPoint(coordinate: coordinate)

        // Calculate scroll delta based on direction and amount
        // Each unit of scroll is approximately 10 pixels of scroll wheel movement
        let scrollAmount = Int32(amount * 10)

        var deltaX: Int32 = 0
        var deltaY: Int32 = 0

        switch direction {
        case "up":
            deltaY = scrollAmount
        case "down":
            deltaY = -scrollAmount
        case "left":
            deltaX = scrollAmount
        case "right":
            deltaX = -scrollAmount
        default:
            throw ActionError.invalidParameters("Invalid direction: \(direction)")
        }

        // Create scroll event
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw ActionError.executionFailed("Failed to create scroll event")
        }

        scrollEvent.location = point
        scrollEvent.post(tap: .cghidEventTap)

        return ["success": true]
    }

    private func convertToEventPoint(coordinate: [Int]) throws -> CGPoint {
        guard let screen = NSScreen.main else {
            throw ActionError.executionFailed("Failed to get main screen")
        }
        let mapping = computeMapping(screen: screen)
        let x = CGFloat(coordinate[0])
        let y = CGFloat(coordinate[1])
        let screenTopLeftX = (x - mapping.padX) / mapping.scale
        let screenTopLeftY = (y - mapping.padY) / mapping.scale
        let eventX = mapping.frame.minX + screenTopLeftX
        let eventY = mapping.frame.minY + screenTopLeftY
        return CGPoint(x: eventX, y: eventY)
    }
}
