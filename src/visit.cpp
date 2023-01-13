#include "visit.h"
#include "Symbol.h"
#include "utils.h"
#include <cassert>
#include <iostream>
#include <cstring>
#include <cstdlib>
#include <string>
#include <map>
using namespace std;

const char* op2inst[] = {
    "", "", "sgt", "slt", "", "",
    "add", "sub", "mul", "div",
    "rem", "and", "or", "xor",
    "sll", "srl", "sra"
};
  
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

// 函数控制器，用于确定当前函数的参数是第几个
class FunctionController{
private:
    koopa_raw_function_t func;  //当前访问的函数
public:
    FunctionController() = default;
    void setFunc(koopa_raw_function_t f){
        func = f;
    }
    int getParamNum(koopa_raw_value_t v){
        int i = 0;
        for(; i < func->params.len; ++i){
            if(func->params.buffer[i] == (void *)v)
                break;
        }
        return i;
    }
};

RiscvString rvs;
LocalVarAllocator lva;
FunctionController fc;
TempLabelManager tlm;

// 访问 raw program
void Visit(const koopa_raw_program_t &program) {
    // 执行一些其他的必要操作
    
    // 访问所有全局变量
    Visit(program.values);
    // 访问所有函数
    Visit(program.funcs);
}

// 访问 raw slice
void Visit(const koopa_raw_slice_t &slice) {
    for (size_t i = 0; i < slice.len; ++i) {
        auto ptr = slice.buffer[i];
        // 根据 slice 的 kind 决定将 ptr 视作何种元素
        switch (slice.kind) {
        case KOOPA_RSIK_FUNCTION:
            // 访问函数
            Visit(reinterpret_cast<koopa_raw_function_t>(ptr));
            break;
        case KOOPA_RSIK_BASIC_BLOCK:
            // 访问基本块
            Visit(reinterpret_cast<koopa_raw_basic_block_t>(ptr));
            break;
        case KOOPA_RSIK_VALUE:
            // 访问指令/全局变量
            Visit(reinterpret_cast<koopa_raw_value_t>(ptr));
            break;
        default:
            // 我们暂时不会遇到其他内容, 于是不对其做任何处理
            assert(false);
        }
    }
}

// 访问函数
void Visit(const koopa_raw_function_t &func) {
    if(func->bbs.len == 0) return;
    fc.setFunc(func);

    rvs.append("  .text\n");
    rvs.append("  .globl " + string(func->name + 1) + "\n");
    rvs.append(string(func->name + 1)+ ":\n");

    lva.clear();
    // 先扫一遍完成局部变量分配
    allocLocal(func);
    lva.getDelta();

    //  函数的 prologue
    if(lva.delta)
        rvs.sp(-(int)lva.delta);
    if(lva.R){
        rvs.store("ra", "sp", (int)lva.delta - 4);
    }


    // 找到entry block
    size_t e = 0;
    for(e = 0; e < func->bbs.len; ++e){
        auto ptr = reinterpret_cast<koopa_raw_basic_block_t>(func->bbs.buffer[e]);
        if(ptr->name && !strcmp(ptr->name, "%entry")){
            break;
        }
    }
    // 访问 entry block
    Visit(reinterpret_cast<koopa_raw_basic_block_t>(func->bbs.buffer[e]));

    for(size_t i = 0; i < func->bbs.len; ++i){
        if(i == e) continue;
        auto ptr = func->bbs.buffer[i];
        Visit(reinterpret_cast<koopa_raw_basic_block_t>(ptr));
    }

    // 函数的 epilogue 在ret指令完成
    rvs.append("\n\n");
}

// 访问基本块
void Visit(const koopa_raw_basic_block_t &bb) {
    if(bb->name && strcmp(bb->name, "%entry")){
        rvs.label(string(bb->name + 1));
    }
    for(size_t i = 0; i < bb->insts.len; ++i){
        auto ptr = bb->insts.buffer[i];
        Visit(reinterpret_cast<koopa_raw_value_t>(ptr));
    }
}

// 访问指令
void Visit(const koopa_raw_value_t &value) {
    // 根据指令类型判断后续需要如何访问
    const auto &kind = value->kind;

    switch (kind.tag) {
        case KOOPA_RVT_RETURN:
            // 访问 return 指令
            Visit(kind.data.ret);
            break;
        case KOOPA_RVT_INTEGER:
            // 访问 integer 指令
            rvs.append("Control flow should never reach here.\n");
            Visit(kind.data.integer);
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

// 访问return指令
void Visit(const koopa_raw_return_t &value) {
    if(value.value != nullptr) {
        koopa_raw_value_t ret_value = value.value;
        // 特判return一个整数情况
        if(ret_value->kind.tag == KOOPA_RVT_INTEGER){
            int i = Visit(ret_value->kind.data.integer);
            rvs.li("a0", i);
        } else{
            int i = lva.getOffset(ret_value);
            rvs.load("a0", "sp", i);
        }
    }
    if(lva.R){
        rvs.load("ra", "sp", lva.delta - 4);
    }
    if(lva.delta)
        rvs.sp(lva.delta);
    rvs.ret();
}

// 访问koopa_raw_integer_t,结果返回数值
int Visit(const koopa_raw_integer_t &value){
    return value.value;
}

// 访问koopa_raw_binary_t
void  Visit(const koopa_raw_binary_t &value){

    // 把左右操作数加载到t0,t1寄存器
    koopa_raw_value_t l = value.lhs, r = value.rhs;
    int i;
    if(l->kind.tag == KOOPA_RVT_INTEGER){
        i = Visit(l->kind.data.integer);
        rvs.li("t0", i);
    }else{
        i = lva.getOffset(l);
        rvs.load("t0", "sp", i);
    }
    if(r->kind.tag == KOOPA_RVT_INTEGER){
        i = Visit(r->kind.data.integer);
        rvs.li("t1", i);
    }else {
        i = lva.getOffset(r);
        rvs.load("t1", "sp", i);
    }
    // 判断操作符
    if(value.op == KOOPA_RBO_NOT_EQ){
        rvs.binary("xor", "t0" ,"t0", "t1");
        rvs.two("snez", "t0", "t0");
    }else if(value.op == KOOPA_RBO_EQ){
        rvs.binary("xor", "t0" ,"t0", "t1");
        rvs.two("seqz", "t0", "t0");
    }else if(value.op == KOOPA_RBO_GE){
        rvs.binary("slt", "t0", "t0", "t1");
        rvs.two("seqz", "t0", "t0");
    }else if(value.op == KOOPA_RBO_LE){
        rvs.binary("sgt", "t0", "t0", "t1");
        rvs.two("seqz", "t0", "t0");
    }else{
        string op = op2inst[(int)value.op];
        rvs.binary(op, "t0", "t0", "t1");
    }

}

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
        rvs.load("t0", "sp", lva.getOffset(src));
        rvs.load("t0", "t0", 0);
    }
}

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

// 访问jump指令
void Visit(const koopa_raw_jump_t &jump){
    auto name = string(jump.target->name + 1);
    rvs.jump(name);
    return;
}

// 访问 call 指令
void Visit(const koopa_raw_call_t &call){
    for(int i = 0; i < call.args.len; ++i){
        koopa_raw_value_t v = (koopa_raw_value_t)call.args.buffer[i];
        if(v->kind.tag == KOOPA_RVT_INTEGER){
            int j = Visit(v->kind.data.integer);
            if(i < 8){
                rvs.li("a" + to_string(i), j);
            } else {
                rvs.li("t0", j);
                rvs.store("t0", "sp", (i - 8) * 4);
            }
        } else{
            int off = lva.getOffset(v);
            if(i < 8){
                rvs.load("a" + to_string(i), "sp", off);
            } else {
                rvs.load("t0", "sp", off);
                rvs.store("t0", "sp", (i - 8) * 4);
            }
        }
    }
    rvs.call(string(call.callee->name + 1));
    // if(call.callee->ty->data.function.ret->tag ==KOOPA_RTT_INT32)
  
    return;
}

// 访问全局变量
void VisitGlobalVar(koopa_raw_value_t value){
    rvs.append("  .data\n");
    rvs.append("  .globl " + string(value->name + 1) + "\n");
    rvs.append(string(value->name + 1) + ":\n");
    koopa_raw_value_t init = value->kind.data.global_alloc.init;
    auto ty = value->ty->data.pointer.base;
    if(ty->tag == KOOPA_RTT_INT32){
        if(init->kind.tag == KOOPA_RVT_ZERO_INIT){
            rvs.zeroInitInt();
        } else {
            int i = Visit(init->kind.data.integer);
            rvs.word(i);
        }
    } else{
        // see aggragate
        assert (init->kind.tag == KOOPA_RVT_AGGREGATE) ;
        initGlobalArray(init);
    }
    rvs.append("\n");
    return ;
}

void initGlobalArray(koopa_raw_value_t init){
    if(init->kind.tag == KOOPA_RVT_INTEGER){
        int v = Visit(init->kind.data.integer);
        rvs.word(v);
    } else {
        // KOOPA_RVT_AGGREGATE
        auto elems = init->kind.data.aggregate.elems;
        for(int i = 0; i < elems.len; ++i){
            initGlobalArray(reinterpret_cast<koopa_raw_value_t>(elems.buffer[i]));
        }
    }
}

// 访问getelemptr指令
void Visit(const koopa_raw_get_elem_ptr_t& get_elem_ptr){
    // getelemptr @arr, %2
        // la t0, arr
        // li t1 %2
        // li t2 arr.size
        // mul t1 t1 t2
        // add t0 t0 t1
    koopa_raw_value_t src = get_elem_ptr.src, index = get_elem_ptr.index;
    size_t sz = getTypeSize(src->ty->data.pointer.base->data.array.base);
        
    // 将src的地址放到t0
    if(src->kind.tag == KOOPA_RVT_GLOBAL_ALLOC){
        rvs.la("t0", string(src->name + 1));
    }else if(src->kind.tag == KOOPA_RVT_FUNC_ARG_REF){
        // 我们的KoopaIR保证遇不到
    } else if(src->kind.tag == KOOPA_RVT_ALLOC){
        // 栈上就是要找的地址
        size_t offset = lva.getOffset(src);
        if(rvs.immediate(offset)){
            rvs.binary("addi", "t0", "sp", to_string(offset));
        } else {
            rvs.li("t0", offset);
            rvs.binary("add", "t0", "sp", "t0");
        }
    } else {
        // 栈上存的是指针，间接索引
        rvs.load("t0", "sp", lva.getOffset(src));
    }
    // 将index放到t1
    if(index->kind.tag == KOOPA_RVT_INTEGER){
        int v = Visit(index->kind.data.integer);
        rvs.li("t1", v);
    } else {
        // 其他情况就是栈上的临时变量
        rvs.load("t1", "sp", lva.getOffset(index));
    }
    // 将size放到t2
    rvs.li("t2", sz);
    // 计算真实地址 index * size + base
    rvs.binary("mul", "t1", "t1", "t2");
    rvs.binary("add", "t0", "t0", "t1");
}

// 访问getptr指令
void Visit(const koopa_raw_get_ptr_t& get_ptr){
    koopa_raw_value_t src = get_ptr.src, index = get_ptr.index;
    size_t sz = getTypeSize(src->ty->data.pointer.base);

    // 将src的地址放到t0
    if(src->kind.tag == KOOPA_RVT_GLOBAL_ALLOC){
        rvs.la("t0", string(src->name + 1));
    }else if(src->kind.tag == KOOPA_RVT_FUNC_ARG_REF){
        // 我们的KoopaIR保证遇不到
    } else if(src->kind.tag == KOOPA_RVT_ALLOC){
        // 栈上就是要找的地址
        size_t offset = lva.getOffset(src);
        if(rvs.immediate(offset)){
            rvs.binary("addi", "t0", "sp", to_string(offset));
        } else {
            rvs.li("t0", offset);
            rvs.binary("add", "t0", "sp", "t0");
        }
    } else {
        // 栈上存的是指针，间接索引
        rvs.load("t0", "sp", lva.getOffset(src));
    }
    // 将index放到t1
    if(index->kind.tag == KOOPA_RVT_INTEGER){
        int v = Visit(index->kind.data.integer);
        rvs.li("t1", v);
    } else {
        // 其他情况就是栈上的临时变量
        rvs.load("t1", "sp", lva.getOffset(index));
    }
    // 将size放到t2
    rvs.li("t2", sz);
    // 计算真实地址 index * size + base
    rvs.binary("mul", "t1", "t1", "t2");
    rvs.binary("add", "t0", "t0", "t1");
}

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

// 计算类型koopa_raw_type_t的大小
size_t getTypeSize(koopa_raw_type_t ty){
    switch(ty->tag){
        case KOOPA_RTT_INT32:
            return 4;
        case KOOPA_RTT_UNIT:
            return 0;
        case KOOPA_RTT_ARRAY:
            return ty->data.array.len * getTypeSize(ty->data.array.base);
        case KOOPA_RTT_POINTER:
            return 4;
        case KOOPA_RTT_FUNCTION:
            return 0;
    }
    return 0;
}