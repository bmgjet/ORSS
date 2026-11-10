// Copyright (c) bmgjet. All rights reserved.
namespace OkiRomSim.Mcp;

/// What the ROM model (Program66k, linked from OkiRomSim.Mcp) throws when it cannot do what was asked. In Rom Sim Studio this is the MCP
/// server's own exception type; this build has no MCP server, so it is declared here for the three ROM-model files it shares.
public sealed class ToolException(string message) : Exception(message);
