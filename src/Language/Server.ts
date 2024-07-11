import * as fsp from 'fs/promises';
import {
	createConnection,
	TextDocuments,
	ProposedFeatures,
	InitializeParams,
	TextDocumentSyncKind,
	InitializeResult,
	DocumentUri,
	FileChangeType,
} from 'vscode-languageserver/node';

import {
	TextDocument,
} from 'vscode-languageserver-textdocument';

import { ChangeLogLanguageService } from './ChangeLog';
import { LocaleLanguageService } from "./Locale";
import { URI } from 'vscode-uri';

import readdirGlob from 'readdir-glob';
import { LuaLanguageService } from './Lua';

export async function runLanguageServer():Promise<void> {

	const ChangeLog = new ChangeLogLanguageService();
	const Locale = new LocaleLanguageService();
	const Lua = new LuaLanguageService(Locale);

	// Create a connection for the server, using Node's IPC as a transport.
	// Also include all preview / proposed LSP features.
	const connection = createConnection(ProposedFeatures.all);

	// Create a simple text document manager.
	const documents: TextDocuments<TextDocument> = new TextDocuments(TextDocument);

	async function getDocument(uri:DocumentUri) {
		let document = documents.get(uri);
		if (document) { return document; }

		const docuri = URI.parse(uri);
		if (docuri.scheme === "file" && docuri.path.endsWith(".cfg")) {
			//TODO: proper language detection. for now we're only loading locale offline...
			document = TextDocument.create(uri, "factorio-locale", 1, await fsp.readFile(docuri.fsPath, "utf8"));
			return document;
		}

		return undefined;
	}

	async function scanFile(file:DocumentUri) {
		const document = await getDocument(file);
		if (document && document.languageId === "factorio-locale") {
			Locale.loadDocument(document);
		}
	}

	async function scanWorkspaceFolder(folder:DocumentUri) {
		const uri = URI.parse(folder);
		if (uri.scheme === "file") {
			const globber = readdirGlob(uri.fsPath, {pattern: '**/locale/*/*.cfg'});
			globber.on('match', (match:{ relative:string; absolute:string })=>{
				scanFile(URI.file(match.absolute).toString());
			});
			globber.on('error', (err:unknown)=>{
				throw err;
			});
			await new Promise<void>((resolve)=>{
				globber.on('end', ()=>{
					resolve();
				});
			});
		}
	}

	let hasWorkspaceFolderCapability = false;

	connection.onInitialize(async (params: InitializeParams)=>{
		const capabilities = params.capabilities;

		hasWorkspaceFolderCapability = !!(
			capabilities.workspace && !!capabilities.workspace.workspaceFolders
		);
		Locale.hasDiagnosticRelatedInformationCapability = !!(
			capabilities.textDocument &&
			capabilities.textDocument.publishDiagnostics &&
			capabilities.textDocument.publishDiagnostics.relatedInformation
		);

		const result: InitializeResult = {
			capabilities: {
				textDocumentSync: TextDocumentSyncKind.Incremental,
				documentSymbolProvider: true,
				codeActionProvider: true,
				colorProvider: true,

				definitionProvider: true,
				completionProvider: {
					triggerCharacters: ['"', "'", "."],
					allCommitCharacters: ["."],
				},
			},
		};
		if (hasWorkspaceFolderCapability) {
			result.capabilities.workspace = {
				workspaceFolders: {
					supported: true,
					changeNotifications: true,
				},
			};

			// scan workspace
			if (params.workspaceFolders) {
				await Promise.all(params.workspaceFolders.map((folder)=>scanWorkspaceFolder(folder.uri)));
			}

		}
		return result;
	});

	connection.onInitialized(()=>{
		if (hasWorkspaceFolderCapability) {
			connection.workspace.onDidChangeWorkspaceFolders(async (event)=>{
				for (const removed of event.removed) {
					Locale.clearFolder(removed.uri);
				}
				for (const added of event.added) {
					await scanWorkspaceFolder(added.uri);
				}
			});
		}
	});

	documents.onDidClose(event=>{
		switch (event.document.languageId) {
			case "factorio-locale":
				connection.sendDiagnostics({ uri: event.document.uri, diagnostics: [] });
				break;

			case "factorio-changelog":
				connection.sendDiagnostics({ uri: event.document.uri, diagnostics: [] });
				break;
		}
	});

	// The content of a text document has changed. This event is emitted
	// when the text document first opened or when its content has changed.
	documents.onDidChangeContent(async (change)=>{
		switch (change.document.languageId) {
			case "factorio-locale":
				Locale.loadDocument(change.document);
				connection.sendDiagnostics({ uri: change.document.uri, diagnostics: await Locale.validateTextDocument(change.document) });
				break;
			case "factorio-changelog":
				connection.sendDiagnostics({ uri: change.document.uri, diagnostics: await ChangeLog.validateTextDocument(change.document) });
				break;
		}
	});

	connection.onDefinition(async (request)=>{
		const doc = await getDocument(request.textDocument.uri);
		if (doc && doc.languageId==="lua") {
			return Lua.onDefinition(request, doc);
		}
		return null;
	});

	connection.onCompletion(async (request)=>{
		const doc = await getDocument(request.textDocument.uri);
		if (doc && doc.languageId==="lua") {
			return {
				isIncomplete: true,
				items: Lua.onCompletion(request, doc),
			};
		}
		return undefined;
	});

	connection.onDidChangeWatchedFiles(async (change)=>{
		for (const filechange of change.changes) {
			switch (filechange.type) {
				case FileChangeType.Deleted:
					Locale.clearDocument(filechange.uri);
					break;

				case FileChangeType.Changed:
				case FileChangeType.Created:
					const document = await getDocument(filechange.uri);
					if (document && document.languageId ==="factorio-locale") {
						Locale.loadDocument(document);
					}
					break;
				default:
					break;
			}
		}
	});

	connection.onDocumentSymbol((request)=>{
		const document = documents.get(request.textDocument.uri);
		if (document) {
			switch (document.languageId) {
				case "factorio-locale":
					return Locale.onDocumentSymbol(document);
				case "factorio-changelog":
					return ChangeLog.onDocumentSymbol(document);
			}
		}
		return null;
	});

	connection.onCodeAction((request)=>{
		const document = documents.get(request.textDocument.uri);
		if (document) {
			switch (document.languageId) {
				case "factorio-locale":
					return Locale.onCodeAction(document, request.range, request.context);
				case "factorio-changelog":
					return ChangeLog.onCodeAction(document, request.range, request.context);
			}
		}
		return null;
	});

	connection.onDocumentColor((request)=>{
		const document = documents.get(request.textDocument.uri);
		if (document) {
			switch (document.languageId) {
				case "factorio-locale":
					return Locale.onDocumentColor(document);
			}
		}
		return null;
	});

	connection.onColorPresentation((request)=>{
		const document = documents.get(request.textDocument.uri);
		if (document) {
			switch (document.languageId) {
				case "factorio-locale":
					return Locale.onColorPresentation(request.color, request.range);
			}
		}
		return null;
	});

	// Make the text document manager listen on the connection
	// for open, change and close text document events
	documents.listen(connection);

	// Listen on the connection
	connection.listen();

	return new Promise<void>(resolve=>{
		connection.onExit(resolve);
	});
}