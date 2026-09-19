import { PluginBase } from './PluginBase';
import { PluginEvent } from './PluginEvent';

// 远程命令插件（kdeconnect.runcommand / .request / .output）——MSG112 §1。
// - 收 `kdeconnect.runcommand`：对端预设命令列表（body.commandList 是**序列化 JSON 字符串**：
//   { "<命令ID>": { "name": "...", "command": "..." } }）
// - 发 `kdeconnect.runcommand.request`：{ key: "<命令ID>" } 请求对端执行
// - 收 `kdeconnect.runcommand.output`：执行输出（id/commandOutput/exitCode/success ...）
export interface RunCommandEntry {
  key: string;
  name: string;
  command: string;
}

interface CommandDef {
  name?: string;
  command?: string;
}

interface RunCommandListBody {
  commandList?: string;
}

interface RunCommandOutputBody {
  id?: string;
  commandStarted?: boolean;
  commandOutput?: string;
  stdout?: string;
  stderr?: string;
  commandFinished?: boolean;
  success?: boolean;
  exitCode?: number;
}

interface RunCommandRequestBody {
  key: string;
}

// 输出回显给 UI 的最大长度（toast 不宜过长）
const OUTPUT_PREVIEW_MAX: number = 160;

export class RunCommandPlugin extends PluginBase {
  private commands: RunCommandEntry[] = [];

  constructor() {
    super();
    this.displayName = 'RunCommand';
    this.description = 'Run preset commands on the peer';
    this.supportedPacketTypes = ['kdeconnect.runcommand', 'kdeconnect.runcommand.output'];
    this.outgoingPacketTypes = ['kdeconnect.runcommand.request'];
  }

  onPacketReceived(packetType: string, body: Object): boolean {
    if (packetType === 'kdeconnect.runcommand') {
      this.handleCommandList(body as RunCommandListBody);
      return true;
    }
    if (packetType === 'kdeconnect.runcommand.output') {
      this.handleOutput(body as RunCommandOutputBody);
      return true;
    }
    return false;
  }

  // UI 读取：当前对端可用命令列表
  commandList(): RunCommandEntry[] {
    return this.commands;
  }

  // UI 触发：请求对端执行某条命令
  run(key: string): boolean {
    const body: RunCommandRequestBody = { key: key };
    const ok: boolean = this.send('kdeconnect.runcommand.request', body);
    this.log(ok ? `run command request sent: ${key}` : `run command request failed: ${key}`);
    return ok;
  }

  private handleCommandList(b: RunCommandListBody): void {
    const raw: string = b.commandList ?? '';
    if (raw.length === 0) {
      this.commands = [];
      this.notify('runcommand.list', '0');
      return;
    }
    try {
      const defs: Record<string, CommandDef> = JSON.parse(raw) as Record<string, CommandDef>;
      const keys: string[] = Object.keys(defs);
      const out: RunCommandEntry[] = [];
      for (const k of keys) {
        const def: CommandDef | undefined = defs[k];
        if (def === undefined) {
          continue;
        }
        const entry: RunCommandEntry = { key: k, name: def.name ?? k, command: def.command ?? '' };
        out.push(entry);
      }
      this.commands = out;
      this.notify('runcommand.list', `${out.length}`);
      this.log(`command list received (${out.length} entries)`);
    } catch (e) {
      this.commands = [];
      this.log('command list parse failed');
    }
  }

  private handleOutput(b: RunCommandOutputBody): void {
    const text: string = b.commandOutput ?? (b.stdout ?? '');
    const success: boolean = b.success ?? false;
    const code: number = b.exitCode ?? -1;
    const preview: string = text.length > OUTPUT_PREVIEW_MAX
      ? text.substring(0, OUTPUT_PREVIEW_MAX) : text;
    const ev: PluginEvent = {
      kind: 'runcommand.output',
      runcommandSuccess: success,
      runcommandExitCode: code,
      runcommandOutput: preview
    };
    this.notifyEvent(ev);
    this.log(`command output: success=${success} exit=${code} (${text.length} chars)`);
  }
}
