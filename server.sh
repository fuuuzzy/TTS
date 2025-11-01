#!/bin/bash
# ========================================
# TTS API 服务器管理脚本
# 功能: 启动, 停止, 重启, 状态查看, 日志查看
# ========================================

set -e  # 遇到错误立即退出

# --- 配置变量 ---
APP_FILE="app.py"
PID_FILE=".app.pid"
LOG_FILE="logs/app.log"
LOG_DIR="logs"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 工具函数 ---

# 打印带颜色的消息
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# 确保日志目录存在
ensure_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        print_info "创建日志目录: $LOG_DIR"
    fi
}

# 获取进程 PID
get_pid() {
    if [ -f "$PID_FILE" ]; then
        cat "$PID_FILE"
    else
        pgrep -f "python.*$APP_FILE" | head -1
    fi
}

# 检查进程是否运行
is_running() {
    local pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        # 清理过期的 PID 文件
        [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
        return 1
    fi
}

# 获取进程状态信息
get_status_info() {
    local pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        local uptime=$(ps -o etime= -p "$pid" | tr -d ' ')
        local cpu=$(ps -o %cpu= -p "$pid" | tr -d ' ')
        local mem=$(ps -o %mem= -p "$pid" | tr -d ' ')
        echo "PID: $pid | 运行时间: $uptime | CPU: ${cpu}% | 内存: ${mem}%"
    else
        echo "未运行"
    fi
}

# --- 主要功能函数 ---

# 停止 API 服务器
stop_api() {
    print_info "正在停止 API 服务器..."
    
    if ! is_running; then
        print_warning "API 服务器未运行"
        return 0
    fi
    
    local pid=$(get_pid)
    print_info "找到进程 PID: $pid"
    
    # 发送 SIGTERM 信号
    kill -TERM "$pid" 2>/dev/null
    
    # 等待进程优雅退出（最多 10 秒）
    local count=0
    while [ $count -lt 10 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            print_success "API 服务器已成功停止"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    # 如果进程仍未退出，强制杀死
    print_warning "进程未响应 SIGTERM，尝试强制终止..."
    kill -9 "$pid" 2>/dev/null
    sleep 1
    
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        print_success "API 服务器已强制停止"
        return 0
    else
        print_error "无法停止进程 $pid"
        return 1
    fi
}

# 停止所有 workers
stop_workers() {
    print_info "正在停止所有 workers..."
    
    # 停止 process_worker
    local process_pids=$(pgrep -f "python.*process_worker.py")
    if [ -n "$process_pids" ]; then
        echo "$process_pids" | xargs kill -TERM 2>/dev/null
        print_info "已发送停止信号给 process workers: $process_pids"
    fi
    
    # 停止 upload_worker
    local upload_pids=$(pgrep -f "python.*upload_worker.py")
    if [ -n "$upload_pids" ]; then
        echo "$upload_pids" | xargs kill -TERM 2>/dev/null
        print_info "已发送停止信号给 upload workers: $upload_pids"
    fi
    
    # 等待 workers 退出
    sleep 2
    
    if [ -z "$(pgrep -f 'python.*worker.py')" ]; then
        print_success "所有 workers 已停止"
    else
        print_warning "部分 workers 仍在运行，可能需要手动清理"
    fi
}

# 启动 API 服务器
start_api() {
    print_info "正在启动 API 服务器..."
    
    if is_running; then
        print_error "API 服务器已在运行中 (PID: $(get_pid))"
        return 1
    fi
    
    # 确保日志目录存在
    ensure_log_dir
    
    # 检查配置文件
    if [ ! -f "config.yaml" ]; then
        print_error "配置文件 config.yaml 不存在"
        return 1
    fi
    
    # 启动服务器
    print_info "使用 uv run 启动服务..."
    nohup uv run python "$APP_FILE" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    
    # 保存 PID
    echo "$pid" > "$PID_FILE"
    
    # 等待服务启动（检查进程是否存活）
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        print_success "API 服务器已启动 (PID: $pid)"
        print_info "日志文件: $LOG_FILE"
        print_info "查看日志: $0 logs"
        return 0
    else
        rm -f "$PID_FILE"
        print_error "服务器启动失败，请检查日志: tail -f $LOG_FILE"
        return 1
    fi
}

# 查看服务状态
show_status() {
    echo "=========================================="
    echo " TTS API 服务状态"
    echo "=========================================="
    echo ""
    
    # API 服务器状态
    echo "📡 API 服务器:"
    if is_running; then
        print_success "运行中"
        echo "   $(get_status_info)"
    else
        print_error "未运行"
    fi
    echo ""
    
    # Process Workers 状态
    echo "⚙️  Process Workers:"
    local process_pids=$(pgrep -f "python.*process_worker.py")
    if [ -n "$process_pids" ]; then
        print_success "运行中"
        echo "   PIDs: $process_pids"
        echo "   数量: $(echo "$process_pids" | wc -l | tr -d ' ')"
    else
        print_warning "未运行"
    fi
    echo ""
    
    # Upload Workers 状态
    echo "📤 Upload Workers:"
    local upload_pids=$(pgrep -f "python.*upload_worker.py")
    if [ -n "$upload_pids" ]; then
        print_success "运行中"
        echo "   PIDs: $upload_pids"
        echo "   数量: $(echo "$upload_pids" | wc -l | tr -d ' ')"
    else
        print_warning "未运行"
    fi
    echo ""
    
    echo "=========================================="
}

# 查看日志
show_logs() {
    local lines=${1:-50}
    
    if [ ! -f "$LOG_FILE" ]; then
        print_error "日志文件不存在: $LOG_FILE"
        return 1
    fi
    
    echo "=========================================="
    echo " 最近 $lines 行日志"
    echo "=========================================="
    tail -n "$lines" "$LOG_FILE"
    echo ""
    print_info "实时查看: tail -f $LOG_FILE"
}

# 跟踪日志
tail_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        print_error "日志文件不存在: $LOG_FILE"
        return 1
    fi
    
    print_info "实时日志 (Ctrl+C 退出):"
    tail -f "$LOG_FILE"
}

# 清理日志和临时文件
cleanup() {
    print_info "正在清理日志和临时文件..."
    
    # 清理日志文件
    if [ -f "$LOG_FILE" ]; then
        > "$LOG_FILE"
        print_success "已清空日志文件"
    fi
    
    # 清理临时目录
    if [ -d "temp" ]; then
        rm -rf temp/*
        print_success "已清空临时文件目录"
    fi
    
    # 清理输出目录（可选，谨慎使用）
    # if [ -d "outputs" ]; then
    #     rm -rf outputs/*
    #     print_success "已清空输出文件目录"
    # fi
    
    print_success "清理完成"
}

# 显示帮助信息
show_help() {
    cat << EOF
========================================
 TTS API 服务器管理脚本
========================================

用法: $0 <command> [options]

命令:
  start          启动 API 服务器
  stop           停止 API 服务器
  restart        重启 API 服务器
  status         查看服务状态
  logs [N]       查看最近 N 行日志 (默认 50 行)
  tail           实时跟踪日志输出
  stop-workers   停止所有 workers
  cleanup        清理日志和临时文件
  help           显示此帮助信息

示例:
  $0 start               # 启动服务器
  $0 stop                # 停止服务器
  $0 restart             # 重启服务器
  $0 status              # 查看状态
  $0 logs 100            # 查看最近 100 行日志
  $0 tail                # 实时查看日志
  $0 stop-workers        # 停止所有 workers
  $0 cleanup             # 清理临时文件

配置:
  应用文件: $APP_FILE
  PID 文件: $PID_FILE
  日志文件: $LOG_FILE

========================================
EOF
}

# --- 主逻辑 ---

COMMAND=${1:-help}

case "$COMMAND" in
    start)
        start_api
        ;;
    stop)
        stop_api
        ;;
    restart)
        echo ""
        print_info "========== 重启 API 服务器 =========="
        stop_api
        sleep 2
        start_api
        echo ""
        print_success "========== 重启完成 =========="
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-50}"
        ;;
    tail)
        tail_logs
        ;;
    stop-workers)
        stop_workers
        ;;
    cleanup)
        cleanup
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "未知命令: $COMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac

exit $?