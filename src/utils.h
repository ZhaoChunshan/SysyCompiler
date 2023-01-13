#pragma once
#include <string>
#include <unordered_map>
#include <set>
#include <vector>
#include <stack>

class KoopaString{
private:
    std::string koopa_str;
public:
    void append(const std::string &s){
        koopa_str += s;
    }

    void binary(const std::string &op, const std::string &rd, const std::string &s1, const std::string &s2){
        koopa_str += "  " + rd + " = " + op + " " + s1 + ", " + s2 + "\n";
    }

    void label(const std::string &s){
        koopa_str += s + ":\n";
    }

    void ret(const std::string &name){
        koopa_str +="  ret " + name + "\n";
    }

    void alloc(const std::string &name){
        koopa_str += "  " + name + " = alloc i32\n";
    }

    void alloc(const std::string &name, const std::string &type_str){
        koopa_str += "  " + name + " = alloc " + type_str + "\n";
    }

    void globalAllocINT(const std::string &name, const std::string &init = "zeroinit"){
        koopa_str += "global " + name + " = alloc i32, " + init + "\n";
    }

    void globalAllocArray(const std::string &name, const std::string &array_type, const std::string &init){
        koopa_str += "global " + name + " = alloc " + array_type + ", " + init + "\n";
    }

    void load(const std::string & to, const std::string &from){
        koopa_str += "  " + to + " = load " + from + '\n';
    }

    void store(const std::string &from, const std::string &to){
        koopa_str += "  store " + from + ", " + to + '\n';
    }

    void br(const std::string &v, const std::string &then_s, const std::string &else_s){
        koopa_str += "  br " + v + ", " + then_s + ", " + else_s + '\n';
    }
    
    void jump(const std::string &label){
        koopa_str += "  jump " + label + '\n';
    }

    void call(const std::string &to, const std::string &func,const std::vector<std::string>& params){
        if(to.length()){
            koopa_str += "  " + to + " = ";
        }else{
            koopa_str += "  ";
        }
        koopa_str += "call " + func +"(";
        if(params.size()){
            int n = params.size();
            koopa_str += params[0];
            for(int i = 1; i < n; ++i){
                koopa_str += ", " + params[i];
            }
        }
        koopa_str += ")\n";
    }

    void getelemptr(const std::string& to, const std::string &from, const int i){
        koopa_str += "  " + to + " = getelemptr " + from + ", " + std::to_string(i) + "\n";
    }

    void getelemptr(const std::string& to, const std::string &from, const std::string& i){
        koopa_str += "  " + to + " = getelemptr " + from + ", " + i + "\n";
    }

    void getptr(const std::string& to, const std::string &from, const std::string& i){
        koopa_str += "  " + to + " = getptr " + from + ", " + i + "\n";
    }

    void declLibFunc(){
        this->append("decl @getint(): i32\n");
        this->append("decl @getch(): i32\n");
        this->append("decl @getarray(*i32): i32\n");
        this->append("decl @putint(i32)\n");
        this->append("decl @putch(i32)\n");
        this->append("decl @putarray(i32, *i32)\n");
        this->append("decl @starttime()\n");
        this->append("decl @stoptime()\n");
        this->append("\n");
    }

    std::string getArrayType(const std::vector<int> &w){
        // int a[w0][w1]...[wn-1]
        std::string ans = "i32";
        for(int i = w.size() - 1; i >= 0; --i){
            ans = "[" + ans + ", " + std::to_string(w[i]) + "]";
        }
        return ans;
    }

    // 数组内容在ptr所指的内存区域，数组类型由len描述. ptr[i]为常量，或者是KoopaIR中的名字
    std::string getInitList(std::string *ptr, const std::vector<int> &len){
        std::string ret = "{";
        if(len.size() == 1){
            int n = len[0];
            ret += ptr[0];
            for(int i = 1; i < n; ++i){
                ret += ", " + ptr[i];
            }
        } else {
            int n = len[0], width = 1;
            std::vector<int> sublen(len.begin() + 1, len.end());
            for(auto iter = len.end() - 1; iter != len.begin(); --iter)
                width *= *iter;
            ret += getInitList(ptr, sublen);
            for(int i = 1; i < n; ++i){
                ret += ", " + getInitList(ptr + width * i, sublen);
            }
        }
        ret += "}";
        return ret;
    }

    

    const char * c_str(){return koopa_str.c_str();}
};


class RiscvString{
private:
    std::string riscv_str;
    /**
     * 默认只用t0 t1 t2
     * t3 t4 t5作为备用，临时的，随时可能被修改，不安全
    */
public:
    bool immediate(int i){ return -2048 <= i && i < 2048; }

    void binary(const std::string &op, const std::string &rd, const std::string &rs1, const std::string &rs2){
    riscv_str += "  " + op + std::string(6-op.length(),' ') + rd + ", " + rs1 + ", " + rs2 + "\n";
    }
    
    void two(const std::string &op, const std::string &a, const std::string &b){
        riscv_str += "  " + op + std::string(6 - op.length(), ' ') + a + ", " + b + "\n";
    }

    void append(const std::string &s){
        riscv_str += s;
    }

    void mov(const std::string &from, const std::string &to){
        riscv_str += "  mv    " + to + ", "  + from + '\n';
    }

    void ret(){
        riscv_str += "  ret\n";
    }

    void li(const std::string &to, int im){
        riscv_str += "  li    " + to + ", " + std::to_string(im) + "\n";
    }

    void load(const std::string &to, const std::string &base ,int offset){
        if(offset >= -2048 && offset < 2048)
            riscv_str += "  lw    " + to + ", " + std::to_string(offset) + "(" + base + ")\n";    
        else{
            this->li("t3", offset);
            this->binary("add", "t3", "t3", base);
            riscv_str += "  lw    " + to + ", " + "0" + "(" + "t3" + ")\n";    
        }
    }


    void store(const std::string &from, const std::string &base ,int offset){
        if(offset >= -2048 && offset < 2048)
            riscv_str += "  sw    " + from + ", " + std::to_string(offset) + "(" + base + ")\n";    
        else{
            this->li("t3", offset);
            this->binary("add", "t3", "t3", base);
            riscv_str += "  sw    " + from + ", " + "0" + "(" + "t3" + ")\n";  
        }
    }

    void sp(int delta){
        if(delta >= -2048 && delta < 2048){
            this->binary("addi", "sp", "sp", std::to_string(delta));
        }else{
            this->li("t0", delta);
            this->binary("add", "sp", "sp", "t0");
        }
    }
    
    void label(const std::string &name){
        this->append(name + ":\n");
    }

    void bnez(const std::string &rs, const std::string &target){
        this->two("bnez", rs, target);
    }

    void jump(const std::string &target){
        this->append("  j     " + target + "\n");
    }

    void call(const std::string &func){
        this->append("  call " + func + "\n");
    }

    void zeroInitInt(){
        this->append("  .zero 4\n");
    }

    void word(int i){
        this->append("  .word " + std::to_string(i) + "\n");
    }

    void la(const std::string &to, const std::string &name){
        this->append("  la    " + to + ", " + name + "\n");
    }

    const char* c_str(){
        return riscv_str.c_str();
    }

};

class BlockController{
private:
    bool f = true;
public:
    bool alive(){
        return f;
    }

    void finish(){
        f = false;
    }

    void set(){
        f = true;
    }
};

class WhileName{
public:
    std::string entry_name, body_name, end_name;
    WhileName(const std::string &_entry, const std::string & _body, const std::string &_end): entry_name(_entry), body_name(_body), end_name(_end){}
};

class WhileStack{
private:
    std::stack<WhileName> whiles;
public:
    void append(const std::string &_entry, const std::string & _body, const std::string &_end){
        whiles.emplace(_entry, _body, _end);
    }
    
    void quit(){
        whiles.pop();
    }

    std::string getEntryName(){
        return whiles.top().entry_name;
    }

    std::string getBodyName(){
        return whiles.top().body_name;
    }

    std::string getEndName(){
        return whiles.top().end_name;
    }
};

// 后端riscv生成时，使用到的临时标号
class TempLabelManager{
private:
    int cnt;
public:
    TempLabelManager():cnt(0){ }
    std::string getTmpLabel(){
        return "Label" + std::to_string(cnt++);
    }
};