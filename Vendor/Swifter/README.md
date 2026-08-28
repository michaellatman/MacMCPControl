# Swifter security patch

Source: https://github.com/httpswift/swifter at 9483a5d459b45c3ffd059f7b55f9638e268632fd (1.5.0), under the included MIT license.

Local changes in HttpParser.swift, Socket.swift, and HttpServerIO.swift bound request bodies, headers, connections, and read time; reject ambiguous framing; free buffers on read errors; and serialize connection cleanup. The application binds explicitly to loopback. Regression tests live in Tests/MacMCPControlTests/HTTPTests.swift. Keep this patch when updating upstream.
