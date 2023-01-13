# SysY编译器设计与实现

## 1 编译器概述

### 1.1 基本功能

这是一个可以将 SysY 语言编译到 RISC-V 汇编的编译器。SysY 语言是一种精简版的C语言，而编译器将生成`RV32IM`范围内的 RISC-V 汇编。该编译器使用的中间表示是 Koopa IR，它先将 SysY 源程序翻译成 Koopa IR，再将 Koopa IR 翻译成 RISC-V 汇编。

在运行编译器时，指定`-koopa`和`-riscv`选项可分别生成 Koopa IR 和 RISC-V 汇编。进入项目文件夹下，执行如下指令：

```sh
make -j4
build/compiler -koopa SysY文件路径 -o KoopaIR文件路径
build/compiler -riscv SysY文件路径 -o RISC-V文件路径
```

### 1.2 主要特点

+ **两层中间表示**: 上层的中间表示是抽象语法树，下层的中间表示是 Koopa IR。实际经过词法分析和语法分析，先得到抽象语法树，之后再通过遍历抽象语法树生成Koopa IR（调用抽象语法树结点的Dump函数）。方便起见，我们把从 SysY 到 Koopa IR 的部分称为编译器的**前端**，而把从 Koopa IR 到目标代码的部分称为编译器的**后端**。

+ **前后端低耦合**: 编译器的前端将生成的正确的 Koopa IR 传递给后端，并没有共享别的数据。
+ **前端维护栈式的符号表**：每进入SysY作用域，栈符号表生长一层；每结束一个作用域，退栈。将 SysY 源程序中的变量、类型等信息保存到符号表，并通过`NameManager`模块保证生成 Koopa IR时，同名的不同作用域下的变量，被分配不同的**名字**(Koopa IR中的具名变量，如`@foo`)。
+ **所有变量局部变量都保存在栈中**: 出于简单起见的实现，没有寄存器分配。
+ **后端扫描函数中的指令完成局部变量分配**：后端的代码生成大体以函数为单位。对一个函数生成代码，要先扫描一遍其指令，利用`LocalVarAllocator`模块，完成局部变量的地址分配(i.e. 每条指令的返回结果在栈中的偏移量)。

## 2 编译器设计

### 2.1 主要模块组成

编译器主要分成如下四大模块：

+ **词法分析模块**: 通过词法分析，将SysY源程序转换为token流。(源代码中`sysy.l`)
+ **语法分析模块**: 通过语法分析，得到`AST.h`中定义的抽象语法树。(源代码中`sysy.y`)
+ **IR生成模块**: 遍历抽象语法树，进行语义分析，得到 Koopa IR 中间表示。(源代码中`AST.[h|cpp]`)
+ **代码生成模块**: 扫描Koopa IR，将其转换为RISC-V代码。(源代码中`visit.[h|cpp]`)

模块之间的数据流图如下。

![模块图](pic/模块图.jpg)

除此以外，还有一些辅助的模块，如`Symbol.[h|cpp]`中定义了类型、符号表相关的类；`utils.h`中定义了一些工具类，例如管理 Koopa IR 的`KoopaString`模块，管理 RISC-V 的`RiscvString`模块。

### 2.2 主要数据结构

#### 2.2.1 抽象语法树

抽象语法树在`AST.h`中定义。所有抽象语法树结点都继承自基类`BaseAST`。

```cpp
class BaseAST {
public:
    virtual ~BaseAST() = default;
};
```

抽象语法树结点类的定义，基本是仿照产生式给出的。例如，产生式

```
FuncDef       ::= FuncType IDENT "(" [FuncFParams] ")" Block;
```

给出的 AST 定义如下：

```cpp
class FuncDefAST : public BaseAST {
public:
    std::unique_ptr<BTypeAST> btype;    // 返回值类型
    std::string ident;                  // 函数名标识符
    std::unique_ptr<FuncFParamsAST> func_params;    // 函数参数, nullptr则无参数
    std::unique_ptr<BlockAST> block;    // 函数体
    void Dump() const;
};
```

其他AST结点的定义方式与之类似，不赘述。

#### 2.2.2 类型

为了记录符号的类型，在`Symbol.h`中定义了专门的类`SysYType`。

```cpp
class SysYType{
    public:
        enum TYPE{
            SYSY_INT, SYSY_INT_CONST, SYSY_FUNC_VOID, SYSY_FUNC_INT,
            SYSY_ARRAY_CONST, SYSY_ARRAY
        };
    
        TYPE ty;
        int value;
        SysYType *next;

        /* 此处省略成员函数... */
};
```

这个类有三个字段，`ty`、`value`和`next`。

+ `ty`表名类型，如`SYSY_INT`表示是一个整型、`SYSY_FUNC_VOID`表示这是一个返回值为空的函数（这里没有记录函数的参数列表类型，因为我们编译器总假定输入的SysY程序是合法的，做了实现上的简化）。
+ `value`只在常量整型和数组时存有意义的值。对于常量整型，它代表常值；对于数组，它代表这一维度的宽度。
+ `next`只在表示数组类型时非空。例如，SysY程序中定义了`int a[4][5]`，那么为了表示`a`的类型，`ty`存`SYSY_ARRAY`, `value`存`4`，`next`指向下一个能表示`int[5]`类型的`SysYType`类。

其实这个类设计也用于处理指针的情况。处理指针时，将`ty`设为`SYSY_ARRAY`或`SYSY_ARRAY_CONST`，`value`设为`-1`表示这是指针, 而`next`表示这个指针所指对象的类型。例如，一个`int (*)[5]`类型，即指向一个长度为`5`的`int`数组的指针，在我们的表示中，是`int [-1][5]`，这和函数参数中的`int a[][5]`很相似。

#### 2.2.3 符号表

主要涉及三个类：`Symbol`、`SymbolTable`和`SymbolTableStack`。

`Symbol`是符号表中的一个表项，记录了SysY中的变量的信息，定义如下：

```cpp
class Symbol{
public:
    std::string ident;   // SysY标识符，诸如x,y
    std::string name;    // KoopaIR中的具名变量，诸如@x_1, @y_1, ..., @n_2
    SysYType *ty;
    Symbol(const std::string &_ident, const std::string &_name, SysYType *_t);
    ~Symbol();
};
```

`SymbolTable`是一个符号表，主要是一个`std::unordered_map<std::string, Symbol *>`类型的表。可以看做是`Symbol`条目按照`ident`字段进行的索引。

```cpp
class SymbolTable{
public:
    const int UNKNOWN = -1;
    std::unordered_map<std::string, Symbol *> symbol_tb;  // ident -> Symbol *
	/* 此处省略成员函数 */
};
```

`SymbolTableStack`是`SymbolTable`组成的栈，同时用命名管理器`NameManager`放置IR中出现重名变量，如下。每进入一个作用域，调用`SymbolTableStack::alloc`，在栈上压入一个新的符号表；而退出则调用`SymbolTableStack::quit`，弹栈。

```cpp
class SymbolTableStack{
private:
    std::deque<std::unique_ptr<SymbolTable>> sym_tb_st;
    NameManager nm;
public:
    const int UNKNOWN = -1;
    void alloc();
    void quit();
    /* 省略了一些成员函数 */
};
```

#### 2.2.4 局部变量地址分配器

在`visit.cpp`中定义了局部变量地址分配的类`LocalVarAllocator`。其中最主要的数据结构是`unordered_map<koopa_raw_value_t, size_t> var_addr`，记录了 Koopa IR 中某些指令（i.e.具有计算结果的指令，`alloc`指令等)的结果作为局部变量在栈中的地址（偏移量，从零计）。

```cpp
class LocalVarAllocator{
public:
    unordered_map<koopa_raw_value_t, size_t> var_addr;    // 记录每个value的偏移量
    // R: 函数中有call则为4，用于保存ra寄存器
    // A: 该函数调用的函数中，参数最多的那个，需要额外分配的第9,10……个参数的空间
    // S: 为这个函数的局部变量分配的栈空间
    size_t R, A, S;
    size_t delta;   // 16字节对齐后的栈帧长度
    
    // 返回存储指令计算结果的局部变量的地址
    size_t getOffset(koopa_raw_value_t value);
    /* 省略了一些成员函数 */
};
```

### 2.3 主要算法设计考虑

这部分概要性地介绍大体流程，实现细节参考第3章。

#### 2.3.1 抽象语法树构建

抽象语法树的构建在词法分析阶段完成，参考代码`sysy.y`。其中定义了对每个产生式进行归约时，需要执行的动作，即代码块。大多数代码块返回一个`BaseAST *`类型的指针，完成一棵子树的构建，传递给上层。依次归约，直至得到抽象语法树的根节点`CompUnitAST`。

#### 2.3.2 Koopa IR 生成

`AST.cpp`全局变量定义`KoopaString ks;`用于管理Koopa IR字符串。从根节点`CompUnitAST`开始，遍历抽象语法树，调用每个抽象语法树结点的`Dump`函数，产生 Koopa IR 加入到`KoopaString ks`之中。

#### 2.3.3 目标代码生成

`visit.cpp`中全局变量定义`RiscvString rvs;`用于管理RISC-V字符串。其中`Visit`是一个重载的函数，完成对程序、全局变量、函数、基本块、指令等的访问，从高层往低层进行，直至访问到指令，即`koopa_raw_value_t`。指令的访问在`void Visit(const koopa_raw_value_t &value)`函数中进行。针对Koopa IR中不同的指令，将调用相应的`Visit`函数，将其翻译为RISC-V汇编，加入到`rvs`中。如果该指令有计算结果，将其存入`t0`寄存器，再将`t0`的内容存到该指令的计算结果对应的局部变量的地址(`lva.getOffset`获得)。

```cpp
void Visit(const koopa_raw_value_t &value) {
    // 根据指令类型判断后续需要如何访问
    const auto &kind = value->kind;

    switch (kind.tag) {
        case KOOPA_RVT_RETURN:
            // 访问 return 指令
            Visit(kind.data.ret);
            break;
        case KOOPA_RVT_INTEGER:
            // "Control flow should never reach here."
            break;
        case KOOPA_RVT_BINARY:
            // 访问二元运算
            Visit(kind.data.binary);
            rvs.store("t0", "sp", lva.getOffset(value));
            break;
        case KOOPA_RVT_ALLOC:
            // 访问栈分配指令，啥都不用管
            break;
        case KOOPA_RVT_LOAD:
            // 加载指令
            Visit(kind.data.load);
            rvs.store("t0", "sp", lva.getOffset(value));
            break;
        case KOOPA_RVT_STORE:
            // 存储指令
            Visit(kind.data.store);
            break;
        case KOOPA_RVT_BRANCH:
            // 条件分支指令
            Visit(kind.data.branch);
            break;
        case KOOPA_RVT_JUMP:
            // 无条件跳转指令
            Visit(kind.data.jump);
            break;
        case KOOPA_RVT_CALL:
            // 访问函数调用
            Visit(kind.data.call);
            if(kind.data.call.callee->ty->data.function.ret->tag == KOOPA_RTT_INT32){
                rvs.store("a0", "sp", lva.getOffset(value));
            }
            break;
        case KOOPA_RVT_GLOBAL_ALLOC:
            // 访问全局变量
            VisitGlobalVar(value);
            break;
        case KOOPA_RVT_GET_ELEM_PTR:
            // 访问getelemptr指令
            Visit(kind.data.get_elem_ptr);
            rvs.store("t0", "sp", lva.getOffset(value));
            break;
        case KOOPA_RVT_GET_PTR:
            Visit(kind.data.get_ptr);
            rvs.store("t0", "sp", lva.getOffset(value));
        default:
            // 其他类型暂时遇不到
            break;
    }
}
```



## 3 编译器实现

### 3.1 使用工具介绍

+ Make：自动化的编译工具。make 工具通过一个称为 `Makefile` 的文件来完成并自动维护编译工作。`Makefile` 需要按照某种语法进行编写，其中说明了如何编译各个源文件并连接生成可执行文件，并定义了源文件之间的依赖关系。编写好`Makefile`后，在命令行简单敲`make`指令即可完成编译，避免了手动输入大量指令的麻烦。
+ Flex：词法分析的工具。基于正则表达式的匹配，得到token流。
+ Bison：语法分析的工具。与Flex配合使用，指定上下文无关文法，通过LR分析，完成对源代码的语法分析，可以得到语法分析树。

### 3.2 SysY语法规范的处理细节

#### 3.2.1 常量、变量、作用域

##### 3.2.1.1 前端实现

> 先介绍命名管理器，再介绍 `SymbolTableStack` ，然后说一说IR生成的大致过程。

首先要介绍如下用于 Koopa IR 命名管理的类 `NameManager` 。`getTmpName`函数返回一个临时符号，依次返回`%0`,`%1`等标号。`getName`函数的输入是一个字符串，即SysY语言中的**标识符(identifier)**，返回一个字符串作为其在Koopa IR中的名字。例如，输入标识符`foo`，可能返回`@foo_0`，`@foo_1`，以此类推。而`getLabelName`与此类似，用于生成Koopa IR中基本块的标签，例如`%then_1`。

```cpp
class NameManager{
private:
    int cnt;
    std::unordered_map<std::string, int> no;
public:
    NameManager():cnt(0){}
    void reset();
    std::string getTmpName();
    std::string getName(const std::string &s);
    std::string getLabelName(const std::string &s);
};
```

其次是栈式的符号表`SymbolTable`。它最重要的两个成员变量，一是封装了命名管理器` NameManager nm`，二是符号表的栈`std::deque<std::unique_ptr<SymbolTable>> sym_tb_st`。该类有两个函数`alloc`、`quit`，分别对应进入新的作用域时压栈、退出作用域时弹栈。此外，还有一系列负责插入的函数、负责查找的函数，以及`getTmpName`、`getLabelName`、`getVarName`三个由命名管理器直接向外提供的接口。

```cpp

class SymbolTableStack{
private:
    std::deque<std::unique_ptr<SymbolTable>> sym_tb_st;
    NameManager nm;
public:
    const int UNKNOWN = -1;
    void alloc();
    void quit();
    void resetNameManager();
    void insert(Symbol *symbol);
    void insert(const std::string &ident, SysYType::TYPE _type, int value);
    void insertINT(const std::string &ident);
    void insertINTCONST(const std::string &ident, int value);
    void insertFUNC(const std::string &ident, SysYType::TYPE _t);
    void insertArray(const std::string &ident, const std::vector<int> &len, SysYType::TYPE _t);
    bool exists(const std::string &ident);
    int getValue(const std::string &ident);
    SysYType *getType(const std::string &ident);
    std::string getName(const std::string &ident);

    std::string getTmpName();   // inherit from name manager
    std::string getLabelName(const std::string &label_ident); // inherit from name manager
    std::string getVarName(const std::string& var);   // aux var name
};
```

以下将选取几个重要的成员函数进行介绍。

插入一个符号表表项`Symbol *`，直接调用栈顶的`SymbolTable`的`insert`函数。如下：

```cpp
void SymbolTableStack::insert(Symbol *symbol){
    sym_tb_st.back()->insert(symbol);
}
```

插入基本类型的符号（非数组），给定SysY标识符`ident`，类型`_type`，初值`value`，向符号表中插入。这将先调用命名管理器`getName`方法，获得这个标识符`ident`在 Koopa IR 中具有的唯一名字，再将其插入栈顶符号表。如下：

```cpp
void SymbolTableStack::insert(const std::string &ident, SysYType::TYPE _type, int value){
    string name = nm.getName(ident);
    sym_tb_st.back()->insert(ident, name, _type, value);
}
```

由此，怎么将`int`型以及`const int`型变量插入符号表是清晰的了：

```cpp
void SymbolTableStack::insertINT(const std::string &ident){
    string name = nm.getName(ident);
    sym_tb_st.back()->insertINT(ident, name);
}

void SymbolTableStack::insertINTCONST(const std::string &ident, int value){
    string name = nm.getName(ident);
    sym_tb_st.back()->insertINTCONST(ident, name, value);
}
```

最后以`getValue`为例，看一下负责查找的函数。这个函数从栈顶往下开始找标识符`ident`，第一次找到就是该`ident`所在的作用域对应的符号表。返回这个表中标识符`ident`对应的`value`。

```cpp
int SymbolTableStack::getValue(const std::string &ident){
    int i = (int)sym_tb_st.size() - 1;
    for(; i >= 0; --i){
        if(sym_tb_st[i]->exists(ident))
            break;
    }
    return sym_tb_st[i]->getValue(ident);
}
```

接下来，举几个例子说明一下这些类在 Koopa IR 生成模块`AST.cpp`中是如何调用的。

在`AST.cpp`中，定义了全局变量`SymbolTableStack st;`表示符号表栈。

抽象语法树的根节点`CompUnitAST`，调用`st.alloc`、`st.quit`确定全局作用域：

```cpp

void CompUnitAST::Dump() const {
    st.alloc(); // 全局作用域
    /* 省略其他必要的工作 */
    st.quit();
}
```

`BlockAST`对应于SysY语言中的用花括号括起来的语句块，进入一个Block就是进入了一个新的作用域。

```cpp
void BlockAST::Dump(bool new_symbol_tb) const {
    // into this Block
    if(new_symbol_tb)
        st.alloc();
    /* do something */
    // out of this block
    st.quit();
}
```

当一个`lval`作为常量表达式的一部分，例如`const int x = y`。此时由`SysY`规范知道`y`归约到文法符号`lval`，且必须是常值，存在于符号表。因此`LValAST::getValue`函数的作用就是查找`y`的值。

```cpp
int LValAST::getValue(){
    return st.getValue(ident);
}
```

再如，`LValAST::Dump`函数的一个作用是得到该变量的值。如果该`lval`是常量，直接用`st.getValue(ident)`返回数值；如果是变量，且`dump_ptr = false`（返回值而非指针），则调用`st.getName(ident)`获得其在Koopa IR中的名称（*i32），再从中load出来即可。

```cpp
string LValAST::Dump(bool dump_ptr)const{
    if(tag == VARIABLE){
        SysYType *ty = st.getType(ident);
        if(ty->ty == SysYType::SYSY_INT_CONST)
            return to_string(st.getValue(ident));
        else if(ty->ty == SysYType::SYSY_INT){
            if(dump_ptr == false){
                string tmp = st.getTmpName();
                ks.load(tmp, st.getName(ident));
                return tmp;
            } else {
                return st.getName(ident);
            }
        } else {
            /* 处理数组名作为地址的情况，如arr */
        }
    } else {
        /* 处理数组的情况，如arr[10] */
    }
}
```

处理赋值语句，如`x = m + n`，在`StmtAST`里完成。如下，`exp`是`ExpAST`类型，通过`Dump`获得右值（数值或者存放值的临时名字）并放入`val`中；`lval`是左值，通过`Dump`设定`dump_ptr = true`，获得存储单元的地址，并用将`val`放入该地址（i.e. `ks.store`)。

```cpp
void StmtAST::Dump() const {
    if(tag == ASSIGN){ // 赋值语句
        string val = exp->Dump();
        string to = lval->Dump(true);
        ks.store(val, to);
    } else /* 其他语句 */
    return;
}
```

##### 3.2.1.2 后端实现

> 主要讨论load，store指令向RISC-V汇编的映射。

2.2.4节介绍了局部变量地址分配的类`LocalVarAllocator`。其更详细的实现细节参考3.2.5.2。在后端(`visit.cpp`)中，定义`LocalVarAllocator`的实例`lva`，对正在扫描的函数进行局部变量分配。分配后，调用`lva.getOffset`可直接获得当前指令的计算结果的局部变量的地址（相对于栈指针的偏移）。在此基础上，实现对load/store的处理。

首先是load的处理，可能对Koopa IR中通过`alloc`获得的全局变量或局部变量进行load，也可能对存有指针的临时符号进行load。

```cpp
// 访问load指令
void Visit(const koopa_raw_load_t &load){
    koopa_raw_value_t src = load.src;

    if(src->kind.tag == KOOPA_RVT_GLOBAL_ALLOC){
        // 全局变量
        rvs.la("t0", string(src->name + 1));
        rvs.load("t0", "t0", 0);
    } else if(src->kind.tag == KOOPA_RVT_ALLOC){
        // 栈分配
        int i = lva.getOffset(src);
        rvs.load("t0", "sp", i);
    } else{
        // 存有指针的临时符号
        rvs.load("t0", "sp", lva.getOffset(src));
        rvs.load("t0", "t0", 0);
    }
}
```

其次是store的处理，作用是将`v`的值存到`d`指定的目的地。首先对`v`做判断，如果`v`是第1~8个参数(对应于`if(i <8)`)，则直接处理掉；其他情况，将`v`的值加载到`t0`寄存器。之后，对目的地`d`做判断，可以是分配的全局变量、分配的局部变量，或者是存有地址的局部变量。将`v`的值放入`d`指定的地址即可。

```cpp

// 访问store指令
void Visit(const koopa_raw_store_t &store){
    koopa_raw_value_t v = store.value, d = store.dest;

    int i, j;
    if(v->kind.tag == KOOPA_RVT_FUNC_ARG_REF){
        i = fc.getParamNum(v);
        if(i < 8){
            string reg = "a" + to_string(i);
            if(d->kind.tag == KOOPA_RVT_GLOBAL_ALLOC){
                rvs.la("t0", string(d->name + 1));
                rvs.store(reg, "t0", 0);
            }else if(d->kind.tag == KOOPA_RVT_ALLOC){
                rvs.store(reg,  "sp", lva.getOffset(d));
            }else{
                // 间接引用
                rvs.load("t0", "sp", lva.getOffset(d));
                rvs.store(reg, "t0", 0);
            }
            return;
        } else{
            i = (i - 8) * 4;
            rvs.load("t0", "sp", i + lva.delta);    // caller 栈帧中
        }
    }else if(v->kind.tag == KOOPA_RVT_INTEGER){
        rvs.li("t0", Visit(v->kind.data.integer));
    } else{
        i = lva.getOffset(v);
        rvs.load("t0", "sp", i);
    }
    if(d->kind.tag == KOOPA_RVT_GLOBAL_ALLOC){
        rvs.la("t1", string(d->name + 1));
        rvs.store("t0", "t1", 0);
    } else if(d->kind.tag == KOOPA_RVT_ALLOC){
        j = lva.getOffset(d);
        rvs.store("t0", "sp", j);
    } else {
        rvs.load("t1", "sp", lva.getOffset(d));
        rvs.store("t0","t1", 0);
    }
    
    return;
}
```

#### 3.2.2 if语句

##### 3.2.2.1 前端实现

这部分没有太多的难点，只介绍二义性文法的处理。使用如下产生式避免二义性：

````ebnf
```
  OtherStmt   ::= LVal "=" Exp ";"
                | [Exp] ";"
                | Block
                | "return" [Exp] ";";
                | "while" "(" Exp ")" Stmt
                | "break" ";"
                | "continue" ";"

  Stmt        ::= MatchedStmt | OpenStmt
  MatchedStmt ::= "if" "(" Exp ")" MatchedStmt "else" MatchedStmt
                | OtherStmt
  OpenStmt    ::= "if" "(" Exp ")" Stmt
                | "if" "(" Exp ")" MatchedStmt "else" OpenStmt
  ```
````

##### 3.2.2.2 后端实现

对`jump`的处理简单，不讨论；以下是对`br`指令的处理。首先从条件值`v`。它可能是立即数或者 Koopa IR 中的临时符号。取出值后，放到`t0`寄存器。如果条件为真，应该调到`true_bb`中。但这里使用了两跳方案，先用`bnez`跳到`tmp_label`，再从`tmp_label`用`j`指令跳到`true_bb`。原因是`j`指令比`bnez`跳的更远。

```cpp
// 访问branch指令
void Visit(const koopa_raw_branch_t &branch){
    auto true_bb = branch.true_bb;
    auto false_bb = branch.false_bb;
    koopa_raw_value_t v = branch.cond;
    if(v->kind.tag == KOOPA_RVT_INTEGER){
        rvs.li("t0", Visit(v->kind.data.integer));
    }else{
        rvs.load("t0", "sp", lva.getOffset(v));
    }
    // 这里，用条件跳转指令跳转范围只有4KB，过不了long_func测试用例
    // 1MB。
    // 因此只用bnez实现分支，然后用jump调到目的地。
    string tmp_label = tlm.getTmpLabel();
    rvs.bnez("t0", tmp_label);
    rvs.jump(string(false_bb->name + 1));
    rvs.label(tmp_label);
    rvs.jump(string(true_bb->name + 1));
    return;
}
```

#### 3.2.3 while语句

这部分后端没有改动，只是对前端的修改。重点是对`break`、`continue`的处理，`break`的作用是跳到循环的结束位置，而`continue`的作用是跳到循环的入口处。当 while 语句嵌套时，怎么决定当前的循环的入口位置和结束位置呢？这就引入了需要维护的数据结构——while栈。

在`utils.h`中定义了如下的辅助数据结构。将每进入一个新的while语句，都要调用`WhileStack::append`将这个while的名字，入口，结束位置保存起来。而结束一个while语句，应该弹栈。从`break`跳出时，用`getEndName`函数获得while结束地址；从`continue`跳转时，用`getEntryName`函数获得while的入口地址。

```cpp

class WhileName{
public:
    std::string entry_name, body_name, end_name;
    WhileName(const std::string &_entry, const std::string & _body, const std::string &_end);
};

class WhileStack{
private:
    std::stack<WhileName> whiles;
public:
    void append(const std::string &_entry, const std::string & _body, const std::string &_end);
    void quit();
    std::string getEntryName();
    std::string getBodyName();
    std::string getEndName();
};

```

#### 3.2.4 短路求值

以对`a||b`计算为例，如果`a`已经是`true`，则`b`不该被计算，计算结果为`true`；只有`a`为`false`，`b`才应该被计算。下面的`LOrExpAST::Dump`正是要做这样的短路求值。先分配一个具名符号`result = 1`, 计算左边的值`lhs`，如果非零，则直接跳转到结尾；如果为零，计算`rhs`的值，并将`rhs`规范化存入`result`中。最终程序返回`result`中的值。

```cpp
string LOrExpAST::Dump() const {
    if(tag == L_AND_EXP) return l_and_exp->Dump();

    string result = st.getVarName("SCRES");
    ks.alloc(result);
    ks.store("1", result);

    string lhs = l_or_exp_1->Dump();

    string then_s = st.getLabelName("then_sc");
    string end_s = st.getLabelName("end_sc");

    ks.br(lhs, end_s, then_s);

    bc.set();
    ks.label(then_s);
    string rhs = l_and_exp_2->Dump();
    string tmp = st.getTmpName();
    ks.binary("ne", tmp, rhs, "0");
    ks.store(tmp, result);
    ks.jump(end_s);

    bc.set();
    ks.label(end_s);
    string ret = st.getTmpName();
    ks.load(ret, result);
    return ret;
}
```

#### 3.2.5 函数

##### 3.2.5.1 前端实现

重点是函数参数的翻译。为了简便，我们为每个参数单独分配一个栈上空间，保存起来。后续都引用这个空间。例如，`int x`是SysY中某函数的参数，Koopa IR 该函数的参数列表中有`@x_0: i32`，我们将再令`@x_1 = alloc i32`，再将参数保存到其中`store @x_0, @x_1`，并将`x`作为标识符，`@x_1`作为IR中的名字，插入到符号表中。后续对`x`的引用，将被符号表指示到`@x_1`。这样做是为了后端对参数的处理更加方便，因为这样的话只有`store`指令会以函数参数为操作数。

具体地，函数参数复制到栈中的工作在`FuncDefAST::Dump`中实现，如下。

```cpp

void FuncDefAST::Dump() const {
    ......

    // 提前进入到函数体内的block，方便后续把参数复制到局部变量中
    st.alloc();
    vector<string> var_names;   //KoopaIR参数列表的名字
    
	......
    
    // 提前把虚参加载到变量中
    if(func_params != nullptr){
        int i = 0;
        for(auto &fp : func_params->func_f_params){
            string var = var_names[i++];

            if(fp->tag == FuncFParamAST::VARIABLE){
                // 将参数复制成局部变量
                st.insertINT(fp->ident);
                string name = st.getName(fp->ident);

                ks.alloc(name);
                ks.store(var, name);
            }else /* 处理数组参数 */
        }
    }
	
    // 函数体具体内容交给block
    if(func_params != nullptr){
        block->Dump(false);
    }else{
        block->Dump();
    }
    ......
}

```



##### 3.2.5.2 后端实现

> 先介绍局部变量分配器`LocalVarAllocator`的实现，后介绍工具类`FunctionController`的实现，最后介绍`allocLocal`函数。

我们的栈帧规范如下图所示。`ra`寄存器存放函数的返回地址，如果一个函数中调用了别的函数，那么它就要保存恢复自己的`ra`寄存器。如果它调用的函数，有的参数列表多于8个，多出的部分也保存在栈中。

![栈帧](pic/栈帧.png)

`LocalVarAllocator`在完整定义如下。2.2.4节已对成员变量做详细介绍。以下是成员函数的介绍。

+ `clear`函数将类初始化，每当进行一个新的函数的局部变量分配时，要调用它
+ `alloc`函数表示要为指令`value`分配一个存储空间，长度为`width`字节
+ `setR`函数将`R`设为`4`，表示函数体内有`call`指令调用别的函数
+ `setA`函数试图用一个更大的`a`更新当前`A`，以确定该函数体内调用的子函数中，参数列表最多的有多少个参数。若最多有`n`个参数，则$A = \max\{ 4(n-8), 0\}$。
+ `exists`函数判断一个指令`value`是否已分配局部变量。
+ `getOffset`函数是最重要的对外接口，返回一条指令`value`所对应局部变量相对于栈指针`sp`的偏移。
+ `getDelta`函数计算`delta`成员变量。`delta`为栈帧的长度，即$A + S + R$的结果向 16 对齐。

```cpp
// 配栈上局部变量的地址
class LocalVarAllocator{
public:
    unordered_map<koopa_raw_value_t, size_t> var_addr;    // 记录每个value的偏移量
    // R: 函数中有call则为4，用于保存ra寄存器
    // A: 该函数调用的函数中，参数最多的那个，需要额外分配的第9,10……个参数的空间
    // S: 为这个函数的局部变量分配的栈空间
    size_t R, A, S;
    size_t delta;   // 16字节对齐后的栈帧长度
    LocalVarAllocator(): R(0), A(0), S(0){} 

    void clear(){
        var_addr.clear();
        R = A = S = 0;
        delta = 0;
    }

    void alloc(koopa_raw_value_t value, size_t width = 4){
        var_addr.insert(make_pair(value, S));
        S += width;
    }

    void setR(){
        R = 4;
    }

    void setA(size_t a){
        A = A > a ? A : a;
    }

    bool exists(koopa_raw_value_t value){
        return var_addr.find(value) != var_addr.end();
    }
    
    size_t getOffset(koopa_raw_value_t value){
        // 大小为A的位置存函数参数
        return var_addr[value] + A;
    }

    void getDelta(){
        int d = S + R + A;
        delta = d%16 ? d + 16 - d %16: d;
    }
};

```

```FunctionController```就是用于确定一个参数是当前函数的第几个参数。核心是`getParamNum`函数，当前参数是该函数的第`i`个参数($ i = 0, 1, \cdots $)。

```cpp
// 函数控制器，用于确定当前函数的参数是第几个
class FunctionController{
private:
    koopa_raw_function_t func;  //当前访问的函数
public:
    FunctionController() = default;
    void setFunc(koopa_raw_function_t f);
    int getParamNum(koopa_raw_value_t v);
};
```

`allocLocal`函数通过使用`LocalVarAllocator lva`，扫描函数完成局部变量分配。

```cpp
// 函数 局部变量分配栈地址
void allocLocal(const koopa_raw_function_t &func){
    for(size_t i = 0; i < func->bbs.len; ++i){
        auto bb = reinterpret_cast<koopa_raw_basic_block_t>(func->bbs.buffer[i]);
        for(int j = 0; j < bb->insts.len; ++j){
            auto value = reinterpret_cast<koopa_raw_value_t>(bb->insts.buffer[j]);

            // 下面开始处理一条指令

            // 特判alloc
            if(value->kind.tag == KOOPA_RVT_ALLOC ){
                int sz = getTypeSize(value->ty->data.pointer.base);
                lva.alloc(value, sz);
                continue;
            }
            if(value->kind.tag == KOOPA_RVT_CALL){
                koopa_raw_call_t c = value->kind.data.call;
                lva.setR();                 // 保存恢复ra
                lva.setA((size_t)max(0, ((int)c.args.len - 8 ) * 4));    // 超过8个参数
            }
            size_t sz = getTypeSize(value->ty);
            if(sz){
                lva.alloc(value, sz);
            }
        }
    }
}   
```

最后，对`call`的处理就是把参数加载到参数寄存器，或者栈帧中，有了`lva`都比较简单，不赘述。

#### 3.2.6 数组

以变量数组（非const的）为例，介绍全局变量数组和局部变量数组的处理。先看AST中的定义

```cpp
class VarDefAST: public BaseAST {
public:
    enum TAG { VARIABLE, ARRAY };
    TAG tag;					// 指明是定义普通变量还是数组
    std::string ident;			// 标识符
    std::vector<std::unique_ptr<ConstExpAST>> const_exps;   // 定义数组各维度的宽度
    std::unique_ptr<InitValAST> init_val;   // 初值, nullptr则无初值
    void Dump(bool is_global = false) const;	// 对该结点生成IR
    void DumpArray(bool is_global = false) const;	// 当该结点是数组时的IR生成
};
```

`InitValAST`是个嵌套的初始化列表，是树形的结构，如下。当`tag = INIT_LIST`时，表示是对数组初始化。此时最核心的函数是`getInitVal`函数，它的作用是对一个类型由`len`指定的数组(i.e. 各维度长依次是`len[0]`, `len[1]`, ...)初始化。初始化的值行优先地放在 ptr 指向的连续的区域。ptr 指向的连续区域的长度为$\prod\limits_{i=0}^{n-1}{len[i]}$. `is_global`指定是否是全局变量数组。这个函数的实现是主要的困难所在，幸好，文档中对初始化列表的理解给出了详尽而清晰的解释：https://pku-minic.github.io/online-doc/#/lv9-array/nd-array

```cpp
class InitValAST : public BaseAST{
public:
    enum TAG { EXP, INIT_LIST};
    TAG tag;
    std::unique_ptr<ExpAST> exp;
    std::vector<std::unique_ptr<InitValAST>> inits; // can be 0, 1, 2,....
    std::string Dump() const;
    void getInitVal(std::string *ptr, const std::vector<int> &len, bool is_global = false) const;
};
```

实现了这个`getInitVal`函数，后面就简单了。下面是`VarDefAST::DumpArray`的实现。该函数先计算数组各维度的长度，放到`len`中，再给出数组的初始化区域`init`。然后用`init_val->getInitVal`填充`init`区域。最后，生成 Koopa IR 即可。这其中涉及一些辅助函数`getArrayType`，`getInitList`,`initArray`等，都不复杂，不赘述。

```cpp
void VarDefAST::DumpArray(bool is_global) const {
    vector<int> len;
    for(auto &ce : const_exps){
        len.push_back(ce->getValue());
    }

    st.insertArray(ident, len, SysYType::SYSY_ARRAY);

    string name = st.getName(ident);
    string array_type = ks.getArrayType(len);
    
    int tot_len = 1;
    for(auto i : len) tot_len *= i;
    string *init = new string[tot_len];
    for(int i = 0; i < tot_len; ++i)
        init[i] = "0";

    if(is_global){
        if(init_val != nullptr){
            init_val->getInitVal(init, len, true);
        }
        ks.globalAllocArray(name, array_type, ks.getInitList(init, len));
    } else {
        ks.alloc(name, array_type);
        if(init_val == nullptr) 
            return;
        init_val->getInitVal(init, len, false);

        initArray(name, init, len);
    }
    return;
}
```

数组作为参数的处理，以及后端的实现，只是比较繁琐情况比较多需要仔细判断，不赘述。
