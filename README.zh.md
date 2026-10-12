# MoonWalk 🌗 —— MoonBit 的时光回溯调试器

**给 MoonBit 做的全知调试器（omniscient debugger）。**
失败的测试只需录制一次。之后可以在它执行过的每一步之间前进、后退，还能问任何一个值：**它为什么是这个值？**

[English](README.md) · [架构设计](docs/ARCHITECTURE.md) · [真实案例：starlark-mbt 的跨平台 bug](docs/case-study-starlark.md) · [开发日志](docs/DEVLOG.md) · [示例](examples/)

![MoonWalk 浏览器查看器：解释一个失败的测试](docs/images/viewer-inventory.png)

## 痛点

MoonBit 的测试大多跑在 wasm-gc 上，这个后端**没有调试器**：不能打断点，不能单步，也看不了变量。测试失败了，常见做法只有一种：到处加 `println`，重跑，读输出，再改，再重跑。

就算有传统调试器，问题也解决不了。它只能往前走，一旦走过了“值出错”的那一刻，只能从头再来。更关键的是，开发者真正想问的通常不是“`x` 现在是多少”，而是“`x` 是**怎么变成这个值的**”。

AI 写的代码越来越多，这个问题也越来越常见。测试失败了，代码却不是你写的，这时最需要的是快速看懂程序到底做了什么。

## MoonWalk 做了什么

* **录制一次，随意回放**：测试里的每条语句、每次调用、参数、返回值、分支决策和赋值都会记下来。可以单步前进或后退，可以步过、步出，也可以拖动时间轴跳到任意时刻。
* **问“为什么”**：点击一个变量，或者运行 `moonwalk why`，就会得到这个值的**因果链**：
  * 产生它的那次赋值；
  * 这次赋值读到的变量和调用的函数；
  * 让这段代码得以执行的 `if`/`match` 分支。

  因果链可以跨函数追踪：从返回值追进被调函数，从参数追回调用方的实参，也能处理方法里通过 `self` 修改字段的情况。这在学术上叫动态切片（dynamic slicing），是根据**真实运行记录**算出来的。
* **零侵入**：不改用户的任何一行代码，也不需要编译器插件或调试符号。`moon test` 支持的后端都能用。
* **人和 AI 都能用**：
  * 终端文本报告；
  * 单文件、离线可用的 HTML 时光回溯查看器；
  * [MCP](https://modelcontextprotocol.io) 服务器。Claude Code、Cursor、Codex 这类编码代理可以直接查询执行历史，不用靠猜、也不用往代码里加打印。

```text
$ moonwalk why -C examples/bank
bank_test.mbt:7: inspect(acc.balance) expected "298", got "296"

self.balance = 296
    #32 bank.mbt:37  self.balance = self.balance - amount - fee * 2
  fee = 2
      #28 bank.mbt:33  let fee = fee_for(amount)
    fee_for(...) returned 2
      because this condition was true
          #24 bank.mbt:23  if amount > 100 {
```

上面这个例子里，手续费被扣了两次（`fee * 2`）。没有加任何 `println`，MoonWalk 沿着录下来的数据流直接找到了这一行。

## 安装

需要先安装 [MoonBit 工具链](https://www.moonbitlang.cn/download)。

```bash
git clone https://github.com/wangzh12023/moonwalk
export PATH="$PWD/moonwalk/bin:$PATH"     # Windows：把 moonwalk\bin 加入 PATH
moonwalk --help                           # 首次运行时自动编译
```

MoonWalk 本身也是用 MoonBit 写的，编译成 WebAssembly 后由工具链自带的 `moonrun` 运行。Linux、macOS 和 Windows 都能用。

## 用法

| 命令 | 作用 |
|---|---|
| `moonwalk list` | 列出模块里的所有测试 |
| `moonwalk record [测试]` | 录制测试，打印带缩进的执行过程；`测试` 可以是测试名、名字的一部分，或 `file:line` |
| `moonwalk record 测试 --html run.html` | 额外生成**单文件时光回溯查看器**，可直接附在 bug 报告里 |
| `moonwalk record 测试 --json run.json` | 导出完整录制数据（JSON） |
| `moonwalk why [测试]` | 解释失败的 `inspect` 检查的那个值 |
| `moonwalk why 测试 --var acc.balance --step 25` | 解释任意变量或字段在任意时刻的值 |
| `moonwalk mcp` | 以 MCP 协议（stdio）为 AI 编码代理提供上面这些能力 |

查看器的操作：

* 时间轴：显示整次运行的调用深度，红线标出失败的检查点；
* 源码视图：变量值以行内注释的形式显示；
* 键盘：`←`/`→` 单步，`↑`/`↓` 步过，`o` 步出，`Home`/`End` 跳到开头或结尾；
* 点击变量可以问“为什么”，因果链上的每一项都能点击跳到对应时刻。

查看器本身也是 MoonBit 写的，用的是 [rabbita](https://github.com/moonbit-community/rabbita) 框架，和命令行共用同一个 `why` 引擎。

## 原理

1. **插桩**：用官方的 [`moonbitlang/parser`](https://github.com/moonbitlang/parser) 解析每个 `.mbt` 文件，然后在 AST 对应的位置以文本编辑的方式插入探针：
   * 函数进入和退出（借助 `defer`，异常退出也能记到）；
   * 语句、绑定、分支决策、`match` 分支和返回值。

   **插桩过程从不插入换行**，所以影子副本里的行号和源码完全一致。
2. **自动修复**：值通过 core 库的 `Debug` trait 渲染。如果某个类型没有实现 `Debug`，就把编译错误映射回引起它的探针，把这个值改成 `<hidden>`，然后重新构建。
3. **运行**：用 `moon test -p … --file … -i …` 单独运行选中的测试，并设置超时。探针事件以 `\u0001MW` 为前缀逐行输出到 stdout，所以测试即使 panic 或死循环，已经录到的部分仍然是一份有效的记录。
4. **解释**：事件流重建成由栈帧和步骤组成的时间线，`why` 在上面反向追踪：
   * 一次读取，追到它之前最后一次写入；
   * 一次调用，追到被调函数的返回表达式；
   * 一个参数，追回调用方传入的实参；
   * 方法里通过 `self` 写的字段，追回调用方的变量；
   * 每一步，都关联到控制它是否执行的分支决策。

## 边界（刻意不做的事）

* 只录制**测试**。有 `fn main` 的程序，可以通过一个调用它的测试来录制。
* 只追踪**被调试模块自己的代码**。对依赖（包括 `moonbitlang/core`）的调用只记一步和它的结果。
* 值是用 `Debug` 渲染出来的快照，默认深度为 6。闭包、泛型类型的值、没有实现 `Debug` 的类型都显示为 `<hidden>`。
* 别名分析按变量路径和字段路径进行。如果对象是通过别的别名被修改的（比如从数组里取出来再改），因果链只能追到那个别名为止。

## 致谢与许可证

MoonWalk 是原创项目，依赖以下项目（都是 Apache-2.0 许可）：

* [`moonbitlang/parser`](https://github.com/moonbitlang/parser)
* [`moonbitlang/async`](https://github.com/moonbitlang/async)
* [`moonbitlang/x`](https://github.com/moonbitlang/x)
* [`moonbit-community/rabbita`](https://github.com/moonbit-community/rabbita)

设计思想参考了以下工作，代码上没有复用它们的实现：

* Bil Lewis 的全知调试（Omniscient Debugging）；
* Ko 和 Myers 的 Whyline；
* Agrawal 和 Horgan 的动态切片。

本项目采用 [Apache License 2.0](LICENSE)。
