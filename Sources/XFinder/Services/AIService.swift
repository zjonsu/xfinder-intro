import Foundation

/// One file-organization step proposed by the LLM.
/// - `action == "move"`: move `file` into the sub-folder `destination` (created if missing).
/// - `action == "delete"`: move `file` to the Trash (recoverable); `destination` is unused.
struct AIOperation: Decodable, Identifiable, Hashable {
    var action: String      // "move" | "delete"
    var file: String
    var destination: String?    // 삭제 액션에는 없음(없거나 빈 문자열)
    var id: String { "\(action):\(file)→\(destination ?? "")" }

    var isDelete: Bool { action == "delete" }
}

/// The LLM's full plan: a list of moves plus a one-line Korean summary.
struct AIPlan: Decodable {
    var operations: [AIOperation]
    var summary: String
}

/// Which LLM backend powers AI file organization.
enum AIProvider: String, CaseIterable, Identifiable {
    case ollama   // 로컬 (Ollama)
    case gemini   // 구글 Gemini (클라우드)
    var id: String { rawValue }
    var label: String { self == .ollama ? "로컬 (Ollama)" : "Gemini" }
}

/// User-chosen AI settings handed to `AIService.organize`.
struct AIConfig {
    var provider: AIProvider
    var geminiAPIKey: String
    var geminiModel: String
    /// 로컬 Ollama 서버 주소(기본 http://localhost:11434). 설정에서 변경 가능.
    var ollamaBaseURL: String = AIService.defaultOllamaBaseURL
    /// 우선 사용할 로컬 모델 이름(기본 gemma4:latest). 비었거나 미설치면 자동 감지.
    var ollamaModel: String = AIService.defaultOllamaModel
    /// When the primary provider is Gemini and it fails, retry on local Ollama.
    var fallbackToOllama: Bool = true

    /// 설정값을 실제 URL로 — 잘못된 값이면 기본 주소로 폴백.
    var resolvedOllamaBase: URL {
        let s = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: s) ?? AIService.ollamaBase
    }
    /// 우선 모델 이름 — 비었으면 기본값.
    var resolvedOllamaModel: String {
        let s = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? AIService.defaultOllamaModel : s
    }
}

/// Errors surfaced to the user with friendly Korean messages.
enum AIError: LocalizedError {
    case notRunning
    case noModel
    case geminiNoKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "로컬 LLM(Ollama)에 연결할 수 없습니다.\n터미널에서 `ollama serve` 가 실행 중인지 확인하세요."
        case .noModel:
            return "사용할 수 있는 채팅 모델이 없습니다.\n`ollama pull gemma4` 등으로 모델을 받아 주세요."
        case .geminiNoKey:
            return "Gemini API 키가 없습니다.\n설정 → AI 모델에서 키를 입력하세요. (aistudio.google.com 에서 발급)"
        case .badResponse(let s):
            return "AI 응답을 이해하지 못했습니다.\n\(s)"
        }
    }
}

/// Turns a natural-language instruction into a concrete file-organization plan,
/// using either a local Ollama server or the Google Gemini cloud API.
enum AIService {
    /// 기본 Ollama 서버 주소(사용자가 설정에서 바꾸지 않았을 때).
    static let defaultOllamaBaseURL = "http://localhost:11434"
    static let ollamaBase = URL(string: defaultOllamaBaseURL)!
    /// Preferred local chat model; auto-detection falls back to any non-embedding model.
    static let defaultOllamaModel = "gemma4:latest"
    /// 하위 호환용 별칭(기존 참조 유지).
    static let preferredOllamaModel = defaultOllamaModel

    // MARK: Entry point

    static func organize(folderName: String, files: [String], instruction: String,
                         config: AIConfig) async throws -> AIPlan {
        let (system, user) = prompt(folderName: folderName, files: files, instruction: instruction)
        do {
            let content: String
            switch config.provider {
            case .ollama:
                content = try await callOllama(system: system, user: user,
                                               base: config.resolvedOllamaBase, preferred: config.resolvedOllamaModel)
            case .gemini:
                content = try await callGemini(system: system, user: user,
                                               apiKey: config.geminiAPIKey, model: config.geminiModel)
            }
            return try parse(content, files: files)
        } catch {
            // Gemini(클라우드)가 실패하면 로컬 Ollama로 한 번 더 시도(폴백).
            if config.provider == .gemini && config.fallbackToOllama {
                let content = try await callOllama(system: system, user: user,
                                                   base: config.resolvedOllamaBase, preferred: config.resolvedOllamaModel)
                return try parse(content, files: files)
            }
            throw error
        }
    }

    // MARK: Prompt

    private static func prompt(folderName: String, files: [String], instruction: String) -> (String, String) {
        let system = """
        You are a file-organization assistant inside a macOS file manager.
        The user gives an instruction in Korean and a list of file names in the current folder.
        Respond with ONLY a JSON object, no prose, of this exact shape:
        {"operations":[{"action":"move","file":"<exact name from the list>","destination":"<sub-folder name>"},{"action":"delete","file":"<exact name from the list>"}],"summary":"<one short Korean sentence>"}
        Two actions are supported:
        - "move": relocate the file into the sub-folder "destination" (created if missing).
        - "delete": move the file to the Trash. This is what the user means by 삭제/지워/없애/버려/휴지통. Files go to the Trash and remain recoverable. Do NOT set "destination" for delete.
        Rules:
        - Use ONLY file names that appear in the provided list; never invent names.
        - Match files by the criteria in the instruction. For "확장자 X" or "X 파일", match files whose name ends with ".X" (case-insensitive). e.g. "hwp 파일 삭제" → delete every file ending in ".hwp".
        - For "move", "destination" is a single sub-folder name (no slashes, no "..", no leading dot). It is created if it does not exist.
        - Only include files that should actually be acted on. If none match, return an empty "operations" array.
        - Folder/destination names should be short and human-friendly, in Korean when natural.
        - The "summary" must state in Korean what will happen (e.g. "hwp 파일 3개를 휴지통으로 옮깁니다.").
        """
        let user = """
        현재 폴더: \(folderName)
        파일 목록: \(jsonArray(files))
        명령: \(instruction)
        """
        return (system, user)
    }

    // MARK: Ollama backend

    /// Picks a chat-capable model from `/api/tags` (skips embedding models like `bge`/`*embed*`).
    /// `preferred` 모델이 설치돼 있으면 그걸, 아니면 임베딩이 아닌 첫 채팅 모델을 쓴다.
    static func ollamaChatModel(base: URL, preferred: String) async throws -> String {
        let url = base.appendingPathComponent("api/tags")
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { throw AIError.notRunning }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let names = ((try? JSONDecoder().decode(Tags.self, from: data))?.models ?? []).map(\.name)
        // 정확히 일치하거나(gemma4:latest), 태그를 뺀 이름이 같으면(gemma4) 우선 모델로 인정.
        let want = preferred.lowercased()
        let wantBase = want.split(separator: ":").first.map(String.init) ?? want
        if let exact = names.first(where: { $0.lowercased() == want || $0.lowercased().split(separator: ":").first.map(String.init) == wantBase && !wantBase.isEmpty }) {
            return exact
        }
        if let chat = names.first(where: { n in
            let l = n.lowercased()
            return !l.contains("embed") && !l.hasPrefix("bge") && !l.hasPrefix("nomic")
        }) { return chat }
        throw AIError.noModel
    }

    private static func callOllama(system: String, user: String, base: URL, preferred: String) async throws -> String {
        let model = try await ollamaChatModel(base: base, preferred: preferred)
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.1],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) } catch { throw AIError.notRunning }
        struct ChatResponse: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw AIError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return chat.message.content
    }

    // MARK: Gemini backend

    private static func callGemini(system: String, user: String, apiKey: String, model: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.geminiNoKey }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gemini-2.5-flash" : model

        var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: key)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.1],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw AIError.badResponse("네트워크 오류: \(error.localizedDescription)") }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Surface Gemini's error message (often a bad/again missing key or model name).
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw AIError.badResponse("Gemini \(http.statusCode): \(msg ?? String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }

        struct GResp: Decodable {
            struct Cand: Decodable { struct Content: Decodable { struct Part: Decodable { let text: String }; let parts: [Part] }; let content: Content }
            let candidates: [Cand]
        }
        guard let g = try? JSONDecoder().decode(GResp.self, from: data),
              let text = g.candidates.first?.content.parts.first?.text else {
            throw AIError.badResponse(String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return text
    }

    // MARK: Parse + validate

    private static func parse(_ content: String, files: [String]) throws -> AIPlan {
        guard let planData = content.data(using: .utf8),
              let plan = try? JSONDecoder().decode(AIPlan.self, from: planData) else {
            throw AIError.badResponse(content)
        }
        let valid = plan.operations.filter { op in
            guard files.contains(op.file) else { return false }
            switch op.action {
            case "move":   return isSafeDestination(op.destination ?? "")
            case "delete": return true   // 휴지통으로 이동(복구 가능) — destination 불필요
            default:       return false
            }
        }
        return AIPlan(operations: valid, summary: plan.summary)
    }

    /// A destination must be a single, non-hidden folder name with no path separators.
    static func isSafeDestination(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.contains("/") && t != ".." && !t.hasPrefix(".") && !t.hasPrefix("~")
    }

    private static func jsonArray(_ items: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: items), encoding: .utf8)) ?? "[]"
    }
}
