#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import json
import random
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

def execute_script(script_path, *args):
    print(f"[DEBUG] 准备执行脚本: {script_path}")
    print(f"[DEBUG] 脚本参数: {args}")
    try:
        result = subprocess.run(
            ['bash', script_path] + list(args),
            capture_output=True, text=True
        )
        print(f"[DEBUG] 脚本执行完成，返回码: {result.returncode}")
        print(f"[DEBUG] 脚本输出: {result.stdout.strip()}")
        if result.stderr:
            print(f"[DEBUG] 脚本错误输出: {result.stderr.strip()}")
        
        try:
            response = json.loads(result.stdout)
            print(f"[DEBUG] 解析脚本JSON响应成功")
            return response
        except json.JSONDecodeError:
            print(f"[WARN] 脚本输出不是有效JSON格式")
            return {"success": False, "message": result.stderr.strip() or "脚本执行失败"}
    except Exception as e:
        print(f"[ERROR] 执行脚本失败: {e}")
        return {"success": False, "message": str(e)}

class CreateUserHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        print("\n" + "="*50)
        print("[REQUEST] 收到新的HTTP POST请求")
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            print(f"[DEBUG] 请求内容长度: {content_length}")
            
            body = self.rfile.read(content_length).decode('utf-8')
            print(f"[DEBUG] 请求体内容: {body}")
            
            data = json.loads(body)
            print(f"[DEBUG] 解析JSON成功")
            
            username = data.get('username')
            mode = data.get('mode')
            uid = data.get('uid')  # 获取可选的UID参数
            print(f"[DEBUG] 提取参数: username={username}, mode={mode}")
            
            if not username or not mode:
                print("[ERROR] 参数缺失: username或mode为空")
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'success': False,
                    'message': 'Missing username or mode parameter'
                }).encode('utf-8'))
                return
            
            script_dir = os.path.dirname(os.path.abspath(__file__))
            print(f"[DEBUG] 脚本目录: {script_dir}")
            
            if mode == 'create':
                print("[DEBUG] 模式: 创建用户")    
                script_path = os.path.join(script_dir, 'user_create.sh')
                print(f"[DEBUG] 用户创建脚本路径: {script_path}")
                result = execute_script(script_path, username, str(uid))
                
            elif mode == 'del':
                print("[DEBUG] 模式: 删除用户")
                script_path = os.path.join(script_dir, 'user_del.sh')
                print(f"[DEBUG] 用户删除脚本路径: {script_path}")
                result = execute_script(script_path, username)
                
            else:
                print(f"[ERROR] 无效模式: {mode}")
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'success': False,
                    'message': f'Invalid mode: {mode}. Use "create" or "del".'
                }).encode('utf-8'))
                return
            
            if result.get('success'):
                print(f"[SUCCESS] 操作成功: {result.get('message')}")
                self.send_response(200)
            else:
                print(f"[FAILURE] 操作失败: {result.get('message')}")
                self.send_response(500)
            
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response_json = json.dumps(result)
            print(f"[DEBUG] 发送响应: {response_json}")
            self.wfile.write(response_json.encode('utf-8'))
                
        except json.JSONDecodeError as e:
            print(f"[ERROR] JSON解析失败: {e}")
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'success': False,
                'message': 'Invalid JSON format'
            }).encode('utf-8'))
        except Exception as e:
            print(f"[ERROR] 请求处理异常: {e}")
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'success': False,
                'message': str(e)
            }).encode('utf-8'))
        print("[REQUEST] 请求处理完成")
        print("="*50 + "\n")
    
    def log_message(self, format, *args):
        pass

def main():
    if len(sys.argv) != 2:
        print("Usage: python user_manage.py <port>")
        sys.exit(1)
    
    port = int(sys.argv[1])
    server_address = ('', port)
    httpd = HTTPServer(server_address, CreateUserHandler)
    
    print(f"\n[INFO] 启动用户管理HTTP服务")
    print(f"[INFO] 监听地址: 0.0.0.0:{port}")
    print(f"[INFO] 服务进程ID: {os.getpid()}")
    print(f"[INFO] 需要root权限才能创建/删除用户")
    print(f"[INFO] 按 Ctrl+C 停止服务\n")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[INFO] 收到停止信号，正在关闭服务...")
        httpd.server_close()
        print("[INFO] 服务已停止")

if __name__ == '__main__':
    main()