export type InsertModelArgs = {
        query: string,
}

export type RunCodeArgs = {
        command: string,
}

export type ToolArgs = {
        tool: string,
        params: any,
}

export type InsertModelToolArgs = {
        tool: "InsertModel",
        params: InsertModelArgs,
}

export type RunCodeToolArgs = {
        tool: "RunCode",
        params: RunCodeArgs,
}

export type ToolFunction = (ToolArgs) -> string?

return {}
