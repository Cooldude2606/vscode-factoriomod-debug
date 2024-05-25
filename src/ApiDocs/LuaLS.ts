import type { Writable } from "stream";
import { version as bundleVersion } from "../../package.json";

function escape_lua_keyword(str:string) {
	const keywords = ["and", "break", "do", "else", "elseif", "end", "false", "for",
		"function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
		"then", "true", "until", "while"];
	return keywords.includes(str)?`${str}_`:str;
}

export function to_lua_ident(str:string) {
	return escape_lua_keyword(str.replace(/[^a-zA-Z0-9]/g, "_").replace(/^([0-9])/, "_$1"));
}

function is_lua_ident(str:string) {
	return !!str.match(/^[a-zA-Z_][a-zA-Z_0-9]*$/);
}

type Description = string|undefined|Promise<string|undefined>;

async function comment_description(output:Writable, description?:Description) {
	if (!description) { return; }
	const desc = await description;
	if (!desc) { return; }
	output.write(`---${desc.replace(/\n/g, "\n---")}\n`);
}

export class LuaLSFile {
	constructor(
		public readonly name:string,
		public readonly app_version:string,
		public readonly meta:string = "_",
	) {}

	private members?:(LuaLSFunction|LuaLSClass|LuaLSAlias|LuaLSEnum)[];

	add(member:LuaLSFunction|LuaLSClass|LuaLSAlias|LuaLSEnum) {
		if (!this.members) {
			this.members = [];
		}
		this.members.push(member);
	}

	async write(output:Writable) {
		if (typeof this.meta === "string") {
			output.write(`---@meta ${this.meta}\n`);
		}
		//output.write(`---@diagnostic disable\n`);
		output.write(`\n`);
		output.write(`--$Factorio ${this.app_version}\n`);
		output.write(`--$Generator ${bundleVersion}\n`);
		output.write(`--$Section ${this.name}\n`);
		output.write(`-- This file is automatically generated. Edits will be overwritten without warning.\n`);
		output.write(`\n`);

		if (this.members) {
			for (const member of this.members) {
				await member.write(output);
			}
		}

	}
}

export type LuaLSType = LuaLSTypeName|LuaLSLiteral|LuaLSFunction|LuaLSDict|LuaLSTuple|LuaLSArray|LuaLSUnion;

export class LuaLSTypeName {
	constructor(
		public readonly name:string,
		public readonly generic_args?:LuaLSType[]
	) {}

	format():string {
		if (this.generic_args) {
			return `${this.name}<${this.generic_args.map(a=>a.format()).join(", ")}>`;
		}
		return this.name;
	}
}

export class LuaLSLiteral {
	constructor(
		public readonly value:string|number|boolean,
	) {}
	format() {
		switch (typeof this.value) {
			case "string":
				return `"${this.value}"`;
			case "number":
			case "boolean":
				return this.value.toString();

			default:
				throw new Error("Invalid value");

		}
	}
}

export class LuaLSDict {
	constructor(
		public readonly key:LuaLSType,
		public readonly value:LuaLSType,
	) {}

	format():string {
		return `{[${this.key.format()}]:${this.value.format()}}`;
	}
}

export class LuaLSArray {
	constructor(
		public readonly member:LuaLSType,
	) {}

	format():string {
		return `(${this.member.format()})[]`;
	}
}

export class LuaLSTuple {
	constructor(
		public readonly members:ReadonlyArray<LuaLSType>,
	) {}

	format():string {
		return `{${this.members.map((m, i)=>`[${i+1}]:${m.format()}`).join(", ")}}`;
	}
}

export class LuaLSUnion {
	constructor(
		public readonly members:ReadonlyArray<LuaLSType>,
	) {}

	format():string {
		return this.members.map(m=>`(${m.format()})`).join("|");
	}
}

export class LuaLSAlias {
	constructor(
		public readonly name:string,
		public readonly type:LuaLSType,
		public readonly description?:Description,
	) {}

	async write(output:Writable) {
		await comment_description(output, this.description);
		output.write(`---@alias ${this.name} ${this.type.format()}\n\n`);
	}
}

export class LuaLSEnum {
	constructor(
		public readonly name:string,
		public readonly fields:ReadonlyArray<LuaLSEnumField>,
		public readonly description?:Description,
	) {}

	async write(output:Writable) {
		await comment_description(output, this.description);
		output.write(`---@enum ${this.name}\n`);

		output.write(`${this.name}={\n`);
		for (const field of this.fields) {
			await field.write(output);
		}
		output.write(`}\n`);
	}
}

export class LuaLSEnumField {
	constructor(
		public readonly name:string,
		public readonly typename:LuaLSTypeName,
		public readonly description?:Description,
	) {}

	async write(output:Writable) {
		await comment_description(output, this.description);
		const name = is_lua_ident(this.name) ? this.name : `["${this.name}"]`;
		output.write(`${name}=#{} --[[@as ${this.typename.format()}]],\n`);
	}
}

export class LuaLSClass {
	constructor(
		public name:string,
	) {}
	description?:Description;
	parents?:LuaLSType[];
	generic_args?:string[];
	global_name?:string;

	private operators?:LuaLSOperator[];
	private call_op?:LuaLSOverload[];

	private fields?:LuaLSField[];
	private functions?:LuaLSFunction[];

	add(member:LuaLSOperator|LuaLSOverload|LuaLSField|LuaLSFunction) {
		if (member instanceof LuaLSOperator) {
			if (!this.operators) {
				this.operators = [];
			}
			this.operators.push(member);
		} else if (member instanceof LuaLSOverload) {
			if (!this.call_op) {
				this.call_op = [];
			}
			this.call_op.push(member);
		} else if (member instanceof LuaLSField) {
			if (!this.fields) {
				this.fields = [];
			}
			this.fields.push(member);
		} else if (member instanceof LuaLSFunction) {
			if (!this.functions) {
				this.functions = [];
			}
			this.functions.push(member);
		}
	}

	async write(output:Writable) {
		output.write(`do\n`);
		await comment_description(output, this.description);
		output.write(`---@class ${this.name}`);
		if (this.generic_args && this.generic_args.length > 0) {
			output.write(`<${this.generic_args.join(",")}>`);
		}
		if (this.parents && this.parents.length > 0) {
			output.write(`:${this.parents.map(t=>t.format()).join(", ")}`);
		}
		output.write(`\n`);

		if (this.fields) {
			for (const field of this.fields) {
				await field.write(output);
			}
		}

		if (this.call_op) {
			for (const call_op of this.call_op) {
				await call_op.write(output);
			}
		}

		if (this.operators) {
			for (const op of this.operators) {
				await op.write(output);
			}
		}

		output.write(`${this.global_name ?? ("local " + to_lua_ident(this.name))}={\n`);

		if (this.functions) {
			for (const func of this.functions) {
				await func.write(output);
			}
		}

		output.write(`}\nend\n\n`);
	}

	format():string {
		if ( this.description || this.parents || this.generic_args || this.global_name || this.functions || this.call_op) {
			throw new Error("Can't inline table with unsupported features");

		}
		if (!this.fields) {
			return `{}`;
		}
		return `{${this.fields.map((f, i)=>{
			if (typeof f.name === "string") {
				return `${f.name}:${f.type.format()}`;
			}
			return `[${f.name.format()}]:${f.type.format()}`;
		}).join(", ")}}`;
	}
}

export class LuaLSOperator {
	constructor(
		public readonly name:"len",
		public readonly type:LuaLSType,
		public readonly input_type?:LuaLSType,
	) {}

	description?:Description;

	async write(output:Writable) {
		await comment_description(output, this.description);
		output.write(`---@operator ${this.name}`);

		if (this.input_type) {
			output.write(`(${this.input_type.format()})`);
		}
		output.write(`:${this.type.format()}\n`);

	}
}


export class LuaLSField {
	constructor(
		public readonly name:string|LuaLSType,
		public readonly type:LuaLSType,
		public readonly description?:Description,
		public readonly optional?:boolean,
	) {}

	async write(output:Writable) {
		await comment_description(output, this.description);

		output.write(`---@field `);
		if (typeof this.name === "string") {
			output.write(this.name);
		} else {
			output.write(`[${this.name.format()}]`);
		}
		if (this.optional) {
			output.write(`?`);
		}
		output.write(` ${this.type.format()}\n`);

	}
}

export class LuaLSOverload {
	constructor(
		public readonly description?:Description,
		public readonly params?:ReadonlyArray<LuaLSParam>,
		public readonly returns?:ReadonlyArray<LuaLSReturn>,
	) {}

	async write(output:Writable) {
		await comment_description(output, this.description);
		let params = "";
		if (this.params) {
			params = this.params.map(p=>`${p.name}${p.optional?'?':''}:${p.type.format()}`).join(", ");
		}
		let returns = "";
		if (this.returns) {
			returns = `:${this.returns.map(r=>r.type.format()).join(", ")}`;
		}
		output.write(`---@overload fun(${params})${returns}\n`);
	}
}

export class LuaLSFunction {
	constructor(
		public readonly name:string|undefined,
		public readonly params?:ReadonlyArray<LuaLSParam>|undefined,
		public readonly returns?:ReadonlyArray<LuaLSReturn>|undefined,
		public readonly description?:Description,
	) {}

	private overloads?:LuaLSOverload[];

	nodiscard?:boolean;

	add(overload:LuaLSOverload) {
		if (!this.overloads) {
			this.overloads = [];
		}
		this.overloads.push(overload);
	}

	async write(output:Writable) {
		await comment_description(output, this.description);
		if (this.params) {
			for (const param of this.params) {
				await param.write(output);
			}
		}
		if (this.returns) {
			for (const ret of this.returns) {
				await ret.write(output);
			}
		}
		if (this.nodiscard) {
			output.write(`---@nodiscard\n`);
		}
		if (this.overloads) {
			for (const ol of this.overloads) {
				await ol.write(output);
			}
		}
		output.write(`${this.name} = function(`);
		if (this.params) {
			output.write(this.params.map(p=>p.name).join(", "));
		}
		output.write(`) end;\n`);
	}

	format():string {
		if ((!this.params || this.params.length === 0 ) && !this.returns) {
			return `function`;
		}
		let params = "";
		if (this.params) {
			params = this.params.map(p=>`${p.name}${p.optional?'?':''}:${p.type.format()}`).join(", ");
		}
		let returns = "";
		if (this.returns) {
			returns = `:${this.returns.map(r=>r.type.format()).join(", ")}`;
		}
		return `fun(${params})${returns}`;
	}
}

export class LuaLSParam {
	constructor(
		public readonly name:string,
		public readonly type:LuaLSType,
		public readonly description?:Description,
		public readonly optional?:boolean,
	) {}

	async write(output:Writable) {
		output.write(`---@param ${this.name}${this.optional?"?":""} ${this.type.format()} ${(await this.description)??""}\n`);
	}
}

export class LuaLSReturn {
	constructor(
		public readonly type:LuaLSType,
		public readonly name?:string,
		public readonly description?:Description,
		public readonly optional?:boolean,
	) {}

	async write(output:Writable) {
		output.write(`---@return ${this.type.format()}${this.optional?"?":""} ${this.name??""}`);
		const desc = await this.description;
		if (desc) {
			output.write(` #${desc}`);
		}
		output.write(`\n`);
	}
}