#pragma once
#include "koopa.h"
#include "Symbol.h"
// 函数声明
void Visit(const koopa_raw_program_t &program);
void Visit(const koopa_raw_slice_t &slice) ;
void Visit(const koopa_raw_function_t &func);
void Visit(const koopa_raw_basic_block_t &bb);
void Visit(const koopa_raw_value_t &value);

void Visit(const koopa_raw_return_t &value);
int Visit(const koopa_raw_integer_t &value);
void Visit(const koopa_raw_binary_t &value);
void Visit(const koopa_raw_load_t &load);
void Visit(const koopa_raw_store_t &store);
void Visit(const koopa_raw_branch_t &branch);
void Visit(const koopa_raw_jump_t &jump);
void Visit(const koopa_raw_call_t &call);
void Visit(const koopa_raw_get_elem_ptr_t& get_elem_ptr);
void Visit(const koopa_raw_get_ptr_t& get_ptr);


void VisitGlobalVar(koopa_raw_value_t value);
void initGlobalArray(koopa_raw_value_t init);

void allocLocal(const koopa_raw_function_t &func);

size_t getTypeSize(koopa_raw_type_t ty);