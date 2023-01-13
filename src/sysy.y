%code requires {
  #include <memory>
  #include <string>
  #include "AST.h"
}

%{

#include <iostream>
#include <memory>
#include <string>
#include "AST.h"

// 声明 lexer 函数和错误处理函数
int yylex();
void yyerror(std::unique_ptr<BaseAST> &ast, const char *s);

using namespace std;

%}

// 定义 parser 函数和错误处理函数的附加参数
%parse-param { std::unique_ptr<BaseAST> &ast }

// yylval 的定义, 我们把它定义成了一个联合体 (union)
%union {
  std::string *str_val;
  int int_val;
  char char_val;
  BaseAST *ast_val;
}

// lexer 返回的所有 token 种类的声明
// 注意 IDENT 和 INT_CONST 会返回 token 的值, 分别对应 str_val 和 int_val
%token VOID INT RETURN LESS_EQ GREAT_EQ EQUAL NOT_EQUAL AND OR CONST IF ELSE WHILE BREAK CONTINUE
%token <str_val> IDENT
%token <int_val> INT_CONST

// 非终结符的类型定义
%type <ast_val> FuncDef Block Stmt Exp PrimaryExp UnaryExp MulExp AddExp RelExp EqExp LAndExp LOrExp Decl ConstDecl VarDecl BType ConstDef VarDef ConstDefList VarDefList ConstInitVal InitVal BlockItemList BlockItem LVal ConstExp MatchedStmt OpenStmt OtherStmt GlobalFuncVarList DeclOrFuncDef FuncFParams FuncFParam FuncRParams ArrayIndexConstExpList ArrayIndexExpList InitValList ConstInitValList
%type <int_val> Number
%type <char_val> UnaryOp 
%%

// 开始符, CompUnit ::= GlobalFuncVarList
CompUnit
  : GlobalFuncVarList {
    auto comp_unit = unique_ptr<CompUnitAST>((CompUnitAST *)$1);
    ast = move(comp_unit);
  }
  ;

GlobalFuncVarList
  : DeclOrFuncDef {
    $$ = $1;
  } 
  ;
  
GlobalFuncVarList
  : GlobalFuncVarList DeclOrFuncDef{
    auto comp_unit = new CompUnitAST();
    auto comp1 = unique_ptr<CompUnitAST>((CompUnitAST *)$1);
    auto comp2 = unique_ptr<CompUnitAST>((CompUnitAST *)$2);
    for(auto &f : comp1->func_defs){
        comp_unit->func_defs.emplace_back(f.release());
    }
    for(auto &f : comp2->func_defs){
        comp_unit->func_defs.emplace_back(f.release());
    }
    for(auto &d : comp1->decls){
        comp_unit->decls.emplace_back(d.release());
    }
    for(auto &d : comp2->decls){
        comp_unit->decls.emplace_back(d.release());
    }
    $$ = comp_unit;
  } 
  ;


DeclOrFuncDef
  : Decl {
    auto comp_unit = new CompUnitAST();
    comp_unit->decls.emplace_back((DeclAST *)$1);
    $$ = comp_unit;
  }
  ;
  
DeclOrFuncDef
  : FuncDef {
    auto comp_unit = new CompUnitAST();
    comp_unit->func_defs.emplace_back((FuncDefAST *)$1);
    $$ = comp_unit;
  } 
  ;

// FuncDef ::= FuncType IDENT '(' ')' Block;
FuncDef
  : BType IDENT '(' ')' Block {
    
    auto func_def = new FuncDefAST();
    func_def->btype = unique_ptr<BTypeAST>((BTypeAST *)$1);
    func_def->ident = *unique_ptr<string>($2);
    func_def->block = unique_ptr<BlockAST>((BlockAST *)$5);
    $$ = func_def;
  }
  ;

// FuncDef ::= FuncType IDENT '(' FuncFParams ')' Block;
FuncDef
  : BType IDENT '(' FuncFParams ')' Block {
    auto func_def = new FuncDefAST();
    func_def->btype = unique_ptr<BTypeAST>((BTypeAST *)$1);
    func_def->ident = *unique_ptr<string>($2);
    func_def->func_params = unique_ptr<FuncFParamsAST>((FuncFParamsAST *)$4);
    func_def->block = unique_ptr<BlockAST>((BlockAST *)$6);
    $$ = func_def;
  }
  ;

FuncFParams
  : FuncFParam {
    auto func_params = new FuncFParamsAST();
    func_params->func_f_params.emplace_back((FuncFParamAST *)$1);
    $$ = func_params;
  } | FuncFParam ',' FuncFParams {
    auto func_params = new FuncFParamsAST();
    func_params->func_f_params.emplace_back((FuncFParamAST *)$1);
    auto params = unique_ptr<FuncFParamsAST>((FuncFParamsAST *)($3));
    int n = params->func_f_params.size();
    for(int i = 0; i < n; ++i){
        func_params->func_f_params.emplace_back(params->func_f_params[i].release());
    }
    $$ = func_params;
  }
  ;

FuncFParam
  : BType IDENT {
    auto func_param = new FuncFParamAST();
    func_param->tag = FuncFParamAST::VARIABLE;
    func_param->btype.reset((BTypeAST *)$1);
    func_param->ident = *unique_ptr<string>($2);
    $$ = func_param;
  } | BType IDENT '[' ']' {
    auto func_param = new FuncFParamAST();
    func_param->tag = FuncFParamAST::ARRAY;
    func_param->btype.reset((BTypeAST *)$1);
    func_param->ident = *unique_ptr<string>($2);
    $$ = func_param;
  } | BType IDENT '[' ']' ArrayIndexConstExpList {
    auto func_param = new FuncFParamAST();
    func_param->tag = FuncFParamAST::ARRAY;
    func_param->btype.reset((BTypeAST *)$1);
    func_param->ident = *unique_ptr<string>($2);
    unique_ptr<ArrayIndexConstExpList> p((ArrayIndexConstExpList *)$5);
    for(auto &ce : p->const_exps){
        func_param->const_exps.emplace_back(ce.release());
    }
    $$ = func_param;
  }
  ;

Block
  : '{' BlockItemList '}' {
    $$ = $2;
  }
  ;

BlockItemList
  : {
    auto block = new BlockAST();
    $$ = block;
  } | BlockItem BlockItemList {
    auto block = new BlockAST();
    auto block_lst = unique_ptr<BlockAST>((BlockAST *)$2);
    block->block_items.emplace_back((BlockItemAST *)$1);
    int n = block_lst->block_items.size();
    for(int i = 0; i < n; ++i){
        block->block_items.emplace_back(block_lst->block_items[i].release());
    }
    $$ = block;
  }
  ;

BlockItem
  : Decl {
    auto block_item = new BlockItemAST();
    block_item->tag = BlockItemAST::DECL;
    block_item->decl = unique_ptr<DeclAST>((DeclAST *)$1);
    $$ = block_item;
  }
  ;

BlockItem
  : Stmt {
    auto block_item = new BlockItemAST();
    block_item->tag = BlockItemAST::STMT;
    block_item->stmt = unique_ptr<StmtAST>((StmtAST *)$1);
    $$ = block_item;
  }
  ;

// LV4.1
Decl 
  : ConstDecl {
    auto decl = new DeclAST();
    decl->tag = DeclAST::CONST_DECL;
    decl->const_decl = unique_ptr<ConstDeclAST>((ConstDeclAST *)$1);
    $$ = decl;
  }
  ;

Decl 
  : VarDecl {
    auto decl = new DeclAST();
    decl->tag = DeclAST::VAR_DECL;
    decl->var_decl = unique_ptr<VarDeclAST>((VarDeclAST *)$1);
    $$ = decl;
  }
  ;

Stmt
  : MatchedStmt {
    $$ = $1;
  } | OpenStmt {
    $$ = $1;
  }
  ;

MatchedStmt
  : IF '(' Exp ')' MatchedStmt ELSE MatchedStmt {
    auto mat_stmt = new StmtAST();
    mat_stmt->tag = StmtAST::IF;
    mat_stmt->exp.reset((ExpAST *) $3);
    mat_stmt->if_stmt.reset((StmtAST *)$5);
    mat_stmt->else_stmt.reset((StmtAST *)$7);
    $$ = mat_stmt;
  } | OtherStmt {
    $$ = $1;
  }
  ;

 OpenStmt
  : IF '(' Exp ')' Stmt {
    auto open_stmt = new StmtAST();
    open_stmt->tag = StmtAST::IF;
    open_stmt->exp.reset((ExpAST *)$3);
    open_stmt->if_stmt.reset((StmtAST *)$5);
    $$ = open_stmt;
  } | IF '(' Exp ')' MatchedStmt ELSE OpenStmt {
    auto open_stmt = new StmtAST();
    open_stmt->tag = StmtAST::IF;
    open_stmt->exp.reset((ExpAST *)$3);
    open_stmt->if_stmt.reset((StmtAST *)$5);
    open_stmt->else_stmt.reset((StmtAST *)$7);
    $$ = open_stmt;
  }
  ;

OtherStmt
  : RETURN Exp ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::RETURN;
    stmt->exp = unique_ptr<ExpAST>((ExpAST *)$2);
    $$ = stmt;
  }
  ;

OtherStmt
  : RETURN  ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::RETURN;
    $$ = stmt;
  }
  ;

OtherStmt 
  : LVal '=' Exp ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::ASSIGN;
    stmt->exp.reset((ExpAST *) $3);
    stmt->lval.reset((LValAST *) $1);
    $$ = stmt;
  }
  ;

OtherStmt
  : ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::EXP;
    $$ = stmt;
  } | Exp ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::EXP;
    stmt->exp.reset((ExpAST *)$1);
    $$ = stmt;
  }
  ;

OtherStmt
  : Block {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::BLOCK;
    stmt->block.reset((BlockAST *)$1);
    $$ = stmt;
  }
  ;

OtherStmt
  : WHILE '(' Exp ')' Stmt {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::WHILE;
    stmt->exp.reset((ExpAST *)$3);
    stmt->stmt.reset((StmtAST *)$5);
    $$ = stmt;
  }
  ;

OtherStmt
  : BREAK ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::BREAK;
    $$ = stmt;
  }
  ;

OtherStmt
  : CONTINUE ';' {
    auto stmt = new StmtAST();
    stmt->tag = StmtAST::CONTINUE;
    $$ = stmt;
  }
  ;

ConstDecl
  : CONST BType ConstDefList ';'{
    auto const_decl = (ConstDeclAST *)$3;
    const_decl->btype = unique_ptr<BTypeAST>((BTypeAST *)$2);
    $$ = const_decl;
  }
  ;

ConstDefList
  : ConstDef ',' ConstDefList {
    auto const_decl = new ConstDeclAST();
    auto const_decl_2 = unique_ptr<ConstDeclAST>((ConstDeclAST *)$3);
    const_decl->const_defs.emplace_back((ConstDefAST *)$1);
    int n = const_decl_2->const_defs.size();
    for(int i = 0; i < n; ++i){
        const_decl->const_defs.emplace_back(const_decl_2->const_defs[i].release());
    }
    $$ = const_decl;
  }
  ;


ConstDefList
  : ConstDef {
    auto const_decl = new ConstDeclAST();
    const_decl->const_defs.emplace_back((ConstDefAST *)$1);
    $$ = const_decl;
  }
  ;

VarDecl
  : BType VarDefList ';' {
    auto var_decl = (VarDeclAST *)$2;
    var_decl->btype = unique_ptr<BTypeAST>((BTypeAST *) $1);
    $$ = var_decl;
  }
  ;

VarDefList
  : VarDef ',' VarDefList {
    auto var_decl = new VarDeclAST();
    auto var_decl_2 = unique_ptr<VarDeclAST>((VarDeclAST *)$3);
    var_decl->var_defs.emplace_back((VarDefAST *)$1);
    int n = var_decl_2->var_defs.size();
    for(int i = 0; i < n; ++i){
        var_decl->var_defs.emplace_back(var_decl_2->var_defs[i].release());
    }
    $$ = var_decl;
  }
  ;

VarDefList
  : VarDef {
    auto var_decl = new VarDeclAST();
    var_decl->var_defs.emplace_back((VarDefAST *)$1);
    $$ = var_decl;
  }
  ;

BType
  : INT {
    auto btype = new BTypeAST();
    btype->tag = BTypeAST::INT;
    $$ = btype;
  } | VOID {
    auto btype = new BTypeAST();
    btype->tag = BTypeAST::VOID;
    $$ = btype;
  }
  ;

ConstDef
  : IDENT '=' ConstInitVal {
    auto const_def = new ConstDefAST();
    const_def->tag = ConstDefAST::VARIABLE;
    const_def->ident = *unique_ptr<string>($1);
    const_def->const_init_val = unique_ptr<ConstInitValAST>((ConstInitValAST *)$3);
    $$ = const_def;
  }
  ;
ConstDef
  : IDENT ArrayIndexConstExpList '=' ConstInitVal {
    auto const_def = new ConstDefAST();
    unique_ptr<ArrayIndexConstExpList> p( (ArrayIndexConstExpList *)$2);
    const_def->tag = ConstDefAST::ARRAY;
    const_def->ident = *unique_ptr<string>($1);
    for(auto &ce : p->const_exps){
        const_def->const_exps.emplace_back(ce.release());
    }
    const_def->const_init_val = unique_ptr<ConstInitValAST>((ConstInitValAST *)$4);
    $$ = const_def;
  }
  ;

ArrayIndexConstExpList
  : '[' ConstExp ']' {
    auto p = new ArrayIndexConstExpList();
    p->const_exps.emplace_back((ConstExpAST *)$2);
    $$ = p;
  } | ArrayIndexConstExpList '[' ConstExp ']' {
    auto p = (ArrayIndexConstExpList *)$1;
    p->const_exps.emplace_back((ConstExpAST *)$3);
    $$ = p;
  }
  ;

ArrayIndexExpList
  : '[' Exp ']' {
    auto p = new ArrayIndexExpList();
    p->exps.emplace_back((ExpAST *)$2);
    $$ = p;
  } | ArrayIndexExpList '[' Exp ']' {
    auto p = (ArrayIndexExpList *)$1;
    p->exps.emplace_back((ExpAST *)$3);
    $$ = p;
  }
  ;


VarDef
  : IDENT{
    auto var_def = new VarDefAST();
    var_def->tag = VarDefAST::VARIABLE;
    var_def->ident = *unique_ptr<string>($1);
    $$ = var_def;
  } | IDENT ArrayIndexConstExpList {
    auto var_def = new VarDefAST();
    var_def->tag = VarDefAST::ARRAY;
    var_def->ident = *unique_ptr<string>($1);
    unique_ptr<ArrayIndexConstExpList> p((ArrayIndexConstExpList *)$2);
    for(auto &ce : p->const_exps){
        var_def->const_exps.emplace_back(ce.release());
    }
    $$ = var_def;
  } | IDENT '=' InitVal {
    auto var_def = new VarDefAST();
    var_def->tag = VarDefAST::VARIABLE;
    var_def->ident = *unique_ptr<string>($1);
    var_def->init_val = unique_ptr<InitValAST>((InitValAST *)$3);
    $$ = var_def;
  } | IDENT ArrayIndexConstExpList '=' InitVal {
    auto var_def = new VarDefAST();
    var_def->tag = VarDefAST::ARRAY;
    var_def->ident = *unique_ptr<string>($1);
    unique_ptr<ArrayIndexConstExpList> p((ArrayIndexConstExpList *)$2);
    for(auto &ce : p->const_exps){
        var_def->const_exps.emplace_back(ce.release());
    }
    var_def->init_val = unique_ptr<InitValAST>((InitValAST *)$4);
    $$ = var_def;
  }
  ;

InitVal
  : Exp{
    auto init_val = new InitValAST();
    init_val->tag = InitValAST::EXP;
    init_val->exp.reset((ExpAST *)$1);
    $$ = init_val;
  } | '{' '}' {
    auto init_val = new InitValAST();
    init_val->tag = InitValAST::INIT_LIST;
    $$ = init_val;
  } | '{' InitValList '}' {
    $$ = $2;
  }

InitValList
  : InitVal {
    auto init_val = new InitValAST();
    init_val->tag = InitValAST::INIT_LIST;
    init_val->inits.emplace_back((InitValAST *)$1);
    $$ = init_val;
  } | InitValList ',' InitVal {
    auto init_val = (InitValAST *)$1;
    init_val->inits.emplace_back((InitValAST *)$3);
    $$ = init_val;
  }
  ;

ConstInitVal
  : ConstExp {
    auto const_init_val = new ConstInitValAST();
    const_init_val->tag = ConstInitValAST::CONST_EXP;
    const_init_val->const_exp = unique_ptr<ConstExpAST>((ConstExpAST *)$1);
    $$ = const_init_val;
  } |'{' '}' {
    auto const_init_val = new ConstInitValAST();
    const_init_val->tag = ConstInitValAST::CONST_INIT_LIST;
    $$ = const_init_val;
  } | '{' ConstInitValList '}' {
    $$ = $2;
  }
  ;

ConstInitValList
  : ConstInitVal {
    auto init_val = new ConstInitValAST();
    init_val->tag = ConstInitValAST::CONST_INIT_LIST;
    init_val->inits.emplace_back((ConstInitValAST *)$1);
    $$ = init_val;
  } | ConstInitValList ',' ConstInitVal {
    auto init_val = (ConstInitValAST *)$1;
    init_val->inits.emplace_back((ConstInitValAST *)$3);
    $$ = init_val;
  }
  ;


LVal
  : IDENT {
    auto lval = new LValAST();
    lval->tag = LValAST::VARIABLE;
    lval->ident = *unique_ptr<string>($1);
    $$ = lval;
  } | IDENT ArrayIndexExpList {
    auto lval = new LValAST();
    unique_ptr<ArrayIndexExpList> p((ArrayIndexExpList *)$2);
    lval->tag = LValAST::ARRAY;
    lval->ident = *unique_ptr<string>($1);
    for(auto &e : p->exps){
        lval->exps.emplace_back(e.release());
    }
    $$ = lval;
  }
  ;

ConstExp
  : Exp {
    auto const_exp = new ConstExpAST();
    const_exp->exp = unique_ptr<ExpAST>((ExpAST *)$1);
    $$ = const_exp;
  }
  ;

Exp
  : LOrExp {
    auto exp = new ExpAST();
    exp->l_or_exp = unique_ptr<LOrExpAST>((LOrExpAST *)$1);
    $$ = exp;
  }
  ;

PrimaryExp
  : '(' Exp ')' {
    auto primary_exp = new PrimaryExpAST();
    primary_exp->tag = PrimaryExpAST::PARENTHESES;
    primary_exp->exp =  unique_ptr<ExpAST>((ExpAST *)$2);
    $$ = primary_exp;
  } 
  ;

PrimaryExp 
  : Number {
    auto primary_exp = new PrimaryExpAST();
    primary_exp->tag = PrimaryExpAST::NUMBER;
    primary_exp->number = $1;
    $$ = primary_exp;
  }
  ;

PrimaryExp 
  : LVal {
    auto primary_exp = new PrimaryExpAST();
    primary_exp->tag = PrimaryExpAST::LVAL;
    primary_exp->lval =  unique_ptr<LValAST>((LValAST *)$1);
    $$ = primary_exp;
  }
  ;

Number
  : INT_CONST {
    $$ = $1;
  }
  ;

UnaryExp
  : PrimaryExp {
    auto unary_exp = new UnaryExpAST();
    unary_exp->tag = UnaryExpAST::PRIMARY_EXP;
    unary_exp->primary_exp = unique_ptr<PrimaryExpAST>((PrimaryExpAST *)$1);
    $$ = unary_exp;
  }
  ;

UnaryExp
  : UnaryOp UnaryExp{
    auto unary_exp = new UnaryExpAST();
    unary_exp->tag = UnaryExpAST::OP_UNITARY_EXP;
    unary_exp->unary_op = $1;
    unary_exp->unary_exp = unique_ptr<UnaryExpAST>((UnaryExpAST *)$2);
    $$ = unary_exp;
  }
  ;

UnaryExp
  : IDENT '(' ')' {
    auto unary_exp = new UnaryExpAST();
    unary_exp->tag = UnaryExpAST::FUNC_CALL;
    unary_exp->ident = *unique_ptr<string>($1);
    $$ = unary_exp;
  } | IDENT '(' FuncRParams ')' {
    auto unary_exp = new UnaryExpAST();
    unary_exp->tag = UnaryExpAST::FUNC_CALL;
    unary_exp->ident = *unique_ptr<string>($1);
    unary_exp->func_params.reset((FuncRParamsAST *)$3);
    $$ = unary_exp;
  }
  ;



MulExp
  : UnaryExp{
    auto mul_exp = new MulExpAST();
    mul_exp->tag = MulExpAST::UNARY_EXP;
    mul_exp->unary_exp = unique_ptr<UnaryExpAST>((UnaryExpAST *)$1);
    $$ = mul_exp;
  }
  ;

MulExp
  : MulExp '*' UnaryExp{
    auto mul_exp = new MulExpAST();
    mul_exp->tag = MulExpAST::OP_MUL_EXP;
    mul_exp->mul_exp_1 = unique_ptr<MulExpAST>((MulExpAST *)$1);
    mul_exp->unary_exp_2 = unique_ptr<UnaryExpAST>((UnaryExpAST *)$3);
    mul_exp->mul_op = '*';
    $$ = mul_exp;
  }
  ;

MulExp
  : MulExp '/' UnaryExp{
    auto mul_exp = new MulExpAST();
    mul_exp->tag = MulExpAST::OP_MUL_EXP;
    mul_exp->mul_exp_1 = unique_ptr<MulExpAST>((MulExpAST *)$1);
    mul_exp->unary_exp_2 = unique_ptr<UnaryExpAST>((UnaryExpAST *)$3);
    mul_exp->mul_op = '/';
    $$ = mul_exp;
  }
  ;
MulExp
  : MulExp '%' UnaryExp{
    auto mul_exp = new MulExpAST();
    mul_exp->tag = MulExpAST::OP_MUL_EXP;
    mul_exp->mul_exp_1 = unique_ptr<MulExpAST>((MulExpAST *)$1);
    mul_exp->unary_exp_2 = unique_ptr<UnaryExpAST>((UnaryExpAST *)$3);
    mul_exp->mul_op = '%';
    $$ = mul_exp;
  }
  ;
AddExp 
  : MulExp {
    auto add_exp = new AddExpAST();
    add_exp->tag = AddExpAST::MUL_EXP;
    add_exp->mul_exp = unique_ptr<MulExpAST>((MulExpAST *)$1);
    $$ = add_exp;
  }
  ;

AddExp 
  : AddExp '+' MulExp {
    auto add_exp = new AddExpAST();
    add_exp->tag = AddExpAST::OP_ADD_EXP;
    add_exp->add_exp_1 = unique_ptr<AddExpAST>((AddExpAST *)$1);
    add_exp->mul_exp_2 = unique_ptr<MulExpAST>((MulExpAST *)$3);
    add_exp->add_op = '+';
    $$ = add_exp;
  }
  ;
AddExp 
  : AddExp '-' MulExp {
    auto add_exp = new AddExpAST();
    add_exp->tag = AddExpAST::OP_ADD_EXP;
    add_exp->add_exp_1 = unique_ptr<AddExpAST>((AddExpAST *)$1);
    add_exp->mul_exp_2 = unique_ptr<MulExpAST>((MulExpAST *)$3);
    add_exp->add_op = '-';
    $$ = add_exp;
  }
  ;

RelExp 
  : AddExp{
    auto rel_exp = new RelExpAST();
    rel_exp->tag = RelExpAST::ADD_EXP;
    rel_exp->add_exp = unique_ptr<AddExpAST>((AddExpAST *)$1);
    $$ = rel_exp;
  }
  ;

RelExp 
  : RelExp '<' AddExp{
    auto rel_exp = new RelExpAST();
    rel_exp->tag = RelExpAST::OP_REL_EXP;
    rel_exp->rel_exp_1 = unique_ptr<RelExpAST>((RelExpAST *)$1);
    rel_exp->add_exp_2 = unique_ptr<AddExpAST>((AddExpAST *)$3);
    rel_exp->rel_op[0] = '<';
    rel_exp->rel_op[1] = 0;
    $$ = rel_exp;
  }
  ;

RelExp 
  : RelExp '>' AddExp{
    auto rel_exp = new RelExpAST();
    rel_exp->tag = RelExpAST::OP_REL_EXP;
    rel_exp->rel_exp_1 = unique_ptr<RelExpAST>((RelExpAST *)$1);
    rel_exp->add_exp_2 = unique_ptr<AddExpAST>((AddExpAST *)$3);
    rel_exp->rel_op[0] = '>';
    rel_exp->rel_op[1] = 0;
    $$ = rel_exp;
  }
  ;
RelExp 
  : RelExp LESS_EQ AddExp{
    auto rel_exp = new RelExpAST();
    rel_exp->tag = RelExpAST::OP_REL_EXP;
    rel_exp->rel_exp_1 = unique_ptr<RelExpAST>((RelExpAST *)$1);
    rel_exp->add_exp_2 = unique_ptr<AddExpAST>((AddExpAST *)$3);
    rel_exp->rel_op[0] = '<';
    rel_exp->rel_op[1] = '=';
    $$ = rel_exp;
  }
  ;
RelExp 
  : RelExp GREAT_EQ AddExp{
    auto rel_exp = new RelExpAST();
    rel_exp->tag = RelExpAST::OP_REL_EXP;
    rel_exp->rel_exp_1 = unique_ptr<RelExpAST>((RelExpAST *)$1);
    rel_exp->add_exp_2 = unique_ptr<AddExpAST>((AddExpAST *)$3);
    rel_exp->rel_op[0] = '>';
    rel_exp->rel_op[1] = '=';
    $$ = rel_exp;
  }
  ;
EqExp 
  : RelExp{
    auto eq_exp = new EqExpAST();
    eq_exp->tag = EqExpAST::REL_EXP;
    eq_exp->rel_exp = unique_ptr<RelExpAST>((RelExpAST *)$1);
    $$ = eq_exp;
  }
  ;

EqExp 
  : EqExp EQUAL RelExp{
    auto eq_exp = new EqExpAST();
    eq_exp->tag = EqExpAST::OP_EQ_EXP;
    eq_exp->eq_exp_1 = unique_ptr<EqExpAST>((EqExpAST *)$1);
    eq_exp->rel_exp_2 = unique_ptr<RelExpAST>((RelExpAST *)$3);
    eq_exp->eq_op = '=';
    $$ = eq_exp;
  }
  ;
EqExp 
  : EqExp NOT_EQUAL RelExp{
    auto eq_exp = new EqExpAST();
    eq_exp->tag = EqExpAST::OP_EQ_EXP;
    eq_exp->eq_exp_1 = unique_ptr<EqExpAST>((EqExpAST *)$1);
    eq_exp->rel_exp_2 = unique_ptr<RelExpAST>((RelExpAST *)$3);
    eq_exp->eq_op = '!';
    $$ = eq_exp;
  }
  ;
LAndExp
  : EqExp {
    auto l_and_exp = new LAndExpAST();
    l_and_exp->tag = LAndExpAST::EQ_EXP;
    l_and_exp->eq_exp = unique_ptr<EqExpAST>((EqExpAST *)$1);
    $$ = l_and_exp;
  }
LAndExp
  : LAndExp AND EqExp{
    auto l_and_exp = new LAndExpAST();
    l_and_exp->tag = LAndExpAST::OP_L_AND_EXP;
    l_and_exp->l_and_exp_1 = unique_ptr<LAndExpAST>((LAndExpAST *)$1);
    l_and_exp->eq_exp_2 = unique_ptr<EqExpAST>((EqExpAST *)$3);
    $$ = l_and_exp;
  }

LOrExp
  : LAndExp {
    auto l_or_exp = new LOrExpAST();
    l_or_exp->tag = LOrExpAST::L_AND_EXP;
    l_or_exp->l_and_exp = unique_ptr<LAndExpAST>((LAndExpAST *)$1);
    $$ = l_or_exp;
  }
LOrExp
  : LOrExp OR LAndExp {
    auto l_or_exp = new LOrExpAST();
    l_or_exp->tag = LOrExpAST::OP_L_OR_EXP;
    l_or_exp->l_or_exp_1 = unique_ptr<LOrExpAST>((LOrExpAST *)$1);
    l_or_exp->l_and_exp_2 = unique_ptr<LAndExpAST>((LAndExpAST *)$3);
    $$ = l_or_exp;
  }

UnaryOp 
  : '+' {
    $$ = '+';
  }
  ;

UnaryOp 
  : '-' {
    $$ = '-';
  }
  ;
UnaryOp 
  : '!' {
    $$ = '!';
  }
  ;

FuncRParams
  : Exp {
    auto params = new FuncRParamsAST();
    params->exps.emplace_back((ExpAST *)$1);
    $$ = params;
  } | Exp ',' FuncRParams {
    auto params = new FuncRParamsAST();
    params->exps.emplace_back((ExpAST *)$1);
    auto p2 = unique_ptr<FuncRParamsAST>((FuncRParamsAST *)$3);
    int n = p2->exps.size();
    for(int i = 0; i < n; ++i){
        params->exps.emplace_back(p2->exps[i].release());
    }
    $$ = params;
  }
  ;

%%

// 定义错误处理函数, 其中第二个参数是错误信息
// parser 如果发生错误 (例如输入的程序出现了语法错误), 就会调用这个函数
void yyerror(unique_ptr<BaseAST> &ast, const char *s) {
  cerr << "error: " << s << endl;
}
