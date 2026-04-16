# COD25 Simulation Framework 调试经验总结

## 1. 这次问题的两层根因

这次仿真问题不是一个单点错误，而是两层问题叠在一起：

### 第一层：`debug_reg_rd` 不能做旁路

FULL 对拍模式不只比较提交信息，还会逐个读取 DUT 的全部寄存器状态。

如果 `debug_reg_rd` 写成了“当 `we=1` 且 `debug_reg_ra == wa` 时直接返回 `wd`”这种旁路逻辑，那么它返回的就不是“寄存器阵列里已经写进去的值”，而是“当前组合逻辑正准备写回的值”。

这会污染 FULL 对拍，导致：

- commit 信息看起来是对的
- 但是 FULL 对拍读出的寄存器状态是错的
- 于是出现“只有 `gr[1]` 不一致”的假象

正确写法是：

- `debug_reg_rd` 只能返回寄存器阵列中的真实值
- 不要对 `debug_reg_rd` 做任何前递或旁路

当前正确实现见 `vsrc/your_vsrc/regfile.v`：

```verilog
assign debug_reg_rd = x[debug_reg_ra];
```

### 第二层：内存镜像文件被错误按 32 位字读取

README 明确规定：

- `instr.ini` / `data.ini` 每行是 1 个 8 位十六进制值
- 文件本质上是字节流
- 连续 4 个字节组成 1 个 32 位字
- 字节顺序是小端

原来 `inst_mem.v`、`data_mem.v` 和 `golden.hpp` 都把 ini 文件按“每行 1 个 32 位 word”去读。这样会把真实的一条 32 位指令拆成 4 条伪指令。

例如文件前 4 行：

```text
93
00
a0
00
```

正确含义是一个 32 位指令：

```text
0x00A00093
```

错误读取方式会把它变成：

```text
0x00000093
0x00000000
0x000000A0
0x00000000
```

这样 CPU 执行的就不是原程序，而是一串完全错误的伪指令流。

## 2. 正确的内存加载方式

### 正确格式

`mem/instr.ini` 和 `mem/data.ini` 的正确格式是：

1. 每行 1 个字节
2. 每行是两位十六进制数
3. 不带分隔符
4. 文件尾保留空行

### 正确装载方法

应当分两步：

1. 先把文件按字节读到 `raw_mem`
2. 再每 4 个字节按小端拼成 1 个 32 位字写入 `mem`

当前 `vsrc/mem_ip_sim/inst_mem.v` 的关键逻辑：

```verilog
$readmemh(`INSTR_MEM_INI, raw_mem);
for(i = 0; i < WORD_COUNT; i = i + 1) begin
    mem[i] = {raw_mem[i * 4 + 3], raw_mem[i * 4 + 2], raw_mem[i * 4 + 1], raw_mem[i * 4]};
end
```

`data_mem.v` 采用同样的规则。

`include/golden.hpp` 也必须使用同样的规则，否则 DUT 和 Golden 看到的程序根本不是同一个程序。

## 3. 为什么会出现 `PC = 0x00440000`

当前配置里：

- 指令存储器起始地址是 `0x00400000`
- 深度是 16
- 这表示共有 `2^16 = 65536` 个 32 位字

总字节数是：

```text
65536 * 4 = 262144 = 0x40000
```

所以这块指令存储器覆盖范围是：

- 起始地址：`0x00400000`
- 结束后一位：`0x00440000`

也就是说，`0x00440000` 正好是指令存储器越界后的第一个地址。

### DUT 这边到底发生了什么

在 `vsrc/top.v` 中：

```verilog
assign imem_paddr = pc - `INSTR_MEM_START;
InstrMem instr_mem(
    .a (imem_paddr[`INSTR_MEM_DEPTH + 1 : 2]),
    .spo (instr)
);
```

把这几句拆开看：

1. `pc` 是 CPU 给出的虚拟地址，例如 `0x00440000`
2. `INSTR_MEM_START` 是 `0x00400000`
3. 所以 `imem_paddr = 0x00440000 - 0x00400000 = 0x00040000`

这个 `imem_paddr` 是“相对地址偏移”，单位仍然是字节。

但 `InstrMem` 的地址口 `a` 不是字节地址，而是 word 地址。因为一个 word 是 4 字节，所以要丢掉最低两位：

- `imem_paddr[1:0]` 表示字内字节偏移
- `imem_paddr[INSTR_MEM_DEPTH+1:2]` 才是第几个 word

当 `INSTR_MEM_DEPTH = 16` 时：

- `a = imem_paddr[17:2]`
- 宽度正好是 16 位

对 `imem_paddr = 0x00040000` 来说：

- byte 偏移是 `0x00040000`
- word 索引是 `0x00040000 >> 2 = 0x10000`

问题来了：

- `0x10000` 需要 17 位二进制表示
- 但 `a` 只有 16 位

所以发生了位截断：

- 理论索引：`1_0000_0000_0000_0000`
- 实际只能保留低 16 位：`0000_0000_0000_0000`

于是 DUT 实际访问了 `mem[0]`。

这就是“地址回卷”的准确含义。不是 `imem_paddr` 自己变窄了，而是：

- `imem_paddr` 仍然是 32 位
- 但是它被接到 `InstrMem.a` 时，只取了 `[17:2]`
- 而 `[17:2]` 这个切片本身只能表示 16 位 word 地址
- 结果把超出的最高位截掉了

### Golden 这边为什么不同

`include/golden.hpp` 的取指逻辑是：

```cpp
__instr = __instr_mem[(__pc - __Configs::instr_mem_start) >> 2];
```

这里没有硬件端口宽度限制，表达式直接算出完整索引：

- `(__pc - instr_mem_start) >> 2 = 0x10000 = 65536`

而 `__instr_mem` 的合法索引只有：

- `0` 到 `65535`

所以 Golden 访问的是越界位置。那次运行中这个越界读取表现成了 `0x00000000`。

因此在越界点：

- DUT 因为地址口宽度限制，回卷到 `mem[0]`
- Golden 因为软件数组索引越界，读出了 `0`

这就是当时 `inst = 0x00000093` 对 `0x00000000` 的来源。

## 4. 单周期 CPU 里，regfile 旁路通常没有必要

这次经验说明了一件很重要的事：

### 单周期 CPU 和流水线 CPU 不能直接套用同一种旁路思路

在单周期 CPU 中：

- 一条指令在一个周期内完成
- 写回发生在时钟边沿
- 下一条指令在下一个周期再读取寄存器

所以跨指令的数据依赖，本来就被时钟边沿自然隔开了。

这意味着：

- `rd1` 和 `rd2` 直接读寄存器阵列，通常已经够用
- 不需要在 regfile 内部再做“如果正在写同一个寄存器，就直接返回 `wd`”这种旁路

这种 regfile 旁路更常见于：

- 某些特定的同步读 RAM 建模
- 或者流水线设计中的特定读写时序修补

如果直接照搬到当前这个单周期结构里，就很容易形成组合环。

### 这次的组合环是怎么形成的

路径是：

1. `cpu.v` 把 `wb_data` 送到 regfile 的 `wd`
2. regfile 的 `rd1/rd2` 又可能直接把 `wd` 旁路回来
3. `rd1/rd2` 参与 ALU 和访存地址计算
4. ALU / mem_ctrl 的结果又参与 `wb_data` 的生成

于是形成：

```text
wb_data -> regfile.wd -> rd1/rd2 -> ALU/mem_ctrl -> wb_data
```

这是典型组合环。

### 当前更稳妥的写法

现在这版 `regfile.v`：

```verilog
assign rd1 = x[ra1];
assign rd2 = x[ra2];
assign debug_reg_rd = x[debug_reg_ra];
```

这是当前单周期实现里更稳妥、更干净的写法。

## 5. 这次修改后如何判断已经正确

当前检查结果是：

1. 重新构建成功
2. 没有新的语法或静态错误
3. FULL 对拍输出 `Hit good trap`
4. 最后一条指令是 `0x00100073`，也就是 `ebreak`
5. 指令数是 22

这说明：

- 程序已经按正确指令流执行结束
- DUT 与 Golden 在 FULL 模式下全程一致
- debug 读口和内存加载逻辑都已经对齐

## 6. 今后调试时的检查清单

### 如果 COMMIT 信息对，但 FULL 寄存器状态不对

优先检查：

- `debug_reg_rd`
- `debug_dmem_rd`
- debug 口是否做了前递/旁路

### 如果仿真直接异常退出，而不是打印 Difference detected

优先检查：

- 测试程序末尾是否真的执行到了 `ebreak`
- 汇编源码里是否只有 `nop`、`j end` 之类的结束方式，却没有显式停机指令
- `instr.ini` 的最后 4 个字节是否真的是 `73 00 10 00`

如果没有 `ebreak`：

- CPU 不会停机
- 程序会继续顺着后面的指令区或零填充区域取指
- 最终可能跑出指令存储器合法范围
- DUT 可能因为地址位宽截断发生回卷
- Golden 可能因为越界取指读到未定义内容，进而抛异常或出现不可预测行为

### 如果取到的指令看起来像单字节扩展值

优先检查：

- `instr.ini` 是否每行 1 字节
- `inst_mem.v` 是否先按字节读入，再拼成 32 位字
- Golden 是否用同样规则加载内存

### 如果 PC 跑到边界地址附近

优先检查：

- 指令存储器起始地址
- 深度对应的总容量
- 地址口位宽是否造成回卷
- Golden 是否发生数组越界

### 如果 Verilator 报 `UNOPTFLAT` 或组合环

优先检查：

- `wb_data` 是否经由 regfile 组合回到 ALU 输入
- regfile 读口是否直接旁路 `wd`
- 是否把流水线旁路写法误用到了单周期 CPU

## 7. 新内存测试暴露出的两个额外问题

在切换到新的 `test_mem.s` 之后，又先后暴露出了两个真实实现问题。

### 问题一：store 写数据路径不完整

报错特征是：

- `pc` 和 `inst` 都对
- `dmem_we` 和 `dmem_wa` 都对
- 但 `dmem_wd` 是 0，而 Golden 期望的是正确待写入的数据

这类现象说明：

- 地址路径没问题
- 写使能没问题
- 出错的是“写入数据本身怎么生成”

根因是原来的 `vsrc/your_vsrc/mem_ctrl.v` 只有 load 的 `rd` 逻辑，没有给 `mem_wd` 赋值。

由于 `DataMem` 是按整字写入的，所以：

- `sw` 必须让 `mem_wd = wd`
- `sh` 必须把 16 位数据合并进旧的 32 位字
- `sb` 必须把 8 位数据合并进旧的 32 位字

也就是说，`mem_ctrl` 不只是“load 提取器”，还必须是“store 整字拼装器”。

### 问题二：这个课程框架里的 `lb/lh` 参考行为不是标准 RV32I 的符号扩展

在这套框架里，参考核 `include/isa.hpp` 对 `lb/lh` 使用的是无符号数据生成器，等价于零扩展。

这意味着：

- `lb` 的参考结果与 `lbu` 相同
- `lh` 的参考结果与 `lhu` 相同

因此如果 CPU 严格按标准 RV32I 去做：

- `lb 0xAB -> 0xFFFFFFAB`
- `lh 0xCDEF -> 0xFFFFCDEF`

那么它会和当前 Golden 不一致。

为了通过这套课程框架的 FULL 对拍，当前控制器中 `lb/lh` 的 `mem_sext` 必须设置为 0。

如果后续你想做“严格标准 RV32I”版本，就不能只改 CPU，还必须同步修改 Golden 或换标准参考模型。

## 8. 随机访存测试还可能暴露出“数据段基址配置错位”

这次换了一份新的随机 asm 之后，仿真并不是先报对拍失败，而是直接抛出了：

```text
terminate called after throwing an instance of 'std::runtime_error'
what(): Invalid data memory address: 268594744
```

把这个十进制地址换成十六进制后，可以得到：

```text
268594744 = 0x10026E38
```

这个地址本身并不离谱。它明显落在 `0x10000000` 起始的数据段里。

真正的问题是：

- 新测试程序默认把数据内存放在 `0x10000000`
- 但当前框架配置里，`include/configs.hpp` 和 `vsrc/configs/configs.vh` 仍然把 `data_mem_start` / `DATA_MEM_START` 写成了 `0x00000000`

于是 Golden 在做地址合法性检查时，会把所有 `0x1000_0000` 开头的访存都判成越界。

### 这个问题的典型症状

症状通常不是：

- `Difference detected`
- 某个寄存器或某次 commit 对不上

而是：

- 仿真刚运行到第一次 load/store
- Golden 直接抛 `Invalid data memory address`
- 程序在对拍之前就异常终止

### 为什么 DUT 侧也必须一起改

`vsrc/top.v` 中数据地址映射是：

```verilog
assign dmem_paddr = dmem_addr - `DATA_MEM_START;
```

如果只改 Golden，不改 Verilog 宏，那么：

- Golden 会把 `0x10000000` 当成合法数据地址
- DUT 仍会按 `0x00000000` 去做减法和截位
- 两边看到的物理索引会不一致

所以这里必须同时修改：

- `include/configs.hpp`
- `vsrc/configs/configs.vh`

让两边都使用：

```text
data_mem_start = 0x10000000
```

### 修正后如何验证

这次统一修改数据内存基址后，重新编译并运行，结果恢复正常：

- FULL difftest 通过
- 输出 `Hit good trap`
- 最后一条指令仍然是 `ebreak`

所以这类问题的根因不是 CPU 访存功能错误，而是“测试程序的数据段地址假设”和“仿真框架的数据内存基址配置”没有对齐。
