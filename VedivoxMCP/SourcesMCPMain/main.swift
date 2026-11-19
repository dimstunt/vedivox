import VedivoxMCPLib

StdioTransport.log("vedivox-mcp: server starting")

while let line = StdioTransport.readLine() {
    if let reply = MCPServer.reply(to: line) { StdioTransport.writeLine(reply) }
}

StdioTransport.log("vedivox-mcp: stdin closed, exiting")
