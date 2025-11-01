#!/bin/bash
# ========================================
# Worker 进程管理脚本（单进程版本）
# 功能: 启动, 停止, 重启, 状态查看
# ========================================

set -e  # 遇到错误立即退出

# --- 配置变量 ---
LOG_DIR="logs"
PID_DIR=".pids"
PROCESS_WORKER_PID="$PID_DIR/process_worker.pid"
UPLOAD_WORKER_PID="$PID_DIR/upload_worker.pid"
PROCESS_WORKER_LOG="$LOG_DIR/process_worker.log"
UPLOAD_WORKER_LOG="$LOG_DIR/upload_worker.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_header() {
    echo -e "${CYAN}$1${NC}"
}

# 确保必要的目录存在
ensure_directories() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        print_info "创建日志目录: $LOG_DIR"
    fi
    
    if [ ! -d "$PID_DIR" ]; then
        mkdir -p "$PID_DIR"
        print_info "创建 PID 目录: $PID_DIR"
    fi
}

# 获取 worker PID
get_worker_pid() {
    local worker_type=$1
    local pid_file="$PID_DIR/${worker_type}_worker.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        # 验证进程是否还在运行
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        else
            # PID 文件过期，删除
            rm -f "$pid_file"
        fi
    fi
    
    # 尝试通过进程名查找
    pgrep -f "uv run python ${worker_type}_worker.py" 2>/dev/null | head -1 || true
}

# 检查 worker 是否运行
is_worker_running() {
    local worker_type=$1
    local pid=$(get_worker_pid "$worker_type")
    [ -n "$pid" ]
}

# 获取 worker 状态信息
get_worker_status() {
    local worker_type=$1
    local pid=$(get_worker_pid "$worker_type")
    
    if [ -z "$pid" ]; then
        echo "   未运行"
        return
    fi
    
    local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    local cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
    local mem=$(ps -o %mem= -p "$pid" 2>/dev/null | tr -d ' ')
    
    echo "   运行中"
    echo "   PID: $pid"
    echo "   运行时间: $uptime | CPU: ${cpu}% | 内存: ${mem}%"
}

# --- 主要功能函数 ---

# 停止指定类型的 worker
stop_worker_type() {
    local worker_type=$1
    local worker_name=$2
    
    local pid=$(get_worker_pid "$worker_type")
    
    if [ -z "$pid" ]; then
        print_warning "$worker_name 未运行"
        return 0
    fi
    
    print_info "正在停止 $worker_name (PID: $pid)..."
    
    # 发送 SIGTERM 信号
    kill -TERM "$pid" 2>/dev/null || true
    
    # 等待进程优雅退出（最多 5 秒）
    local count=0
    while [ $count -lt 5 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_DIR/${worker_type}_worker.pid"
            print_success "$worker_name 已停止"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    # 如果进程仍未退出，强制杀死
    if kill -0 "$pid" 2>/dev/null; then
        print_warning "进程未响应 SIGTERM，强制终止..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
        
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_DIR/${worker_type}_worker.pid"
            print_success "$worker_name 已强制停止"
        else
            print_error "无法停止 $worker_name 进程: $pid"
            return 1
        fi
    fi
}

# 停止所有 Worker 进程
stop_workers() {
    print_header "=========================================="
    print_header " 停止所有 Workers"
    print_header "=========================================="
    echo ""
    
    stop_worker_type "process" "Process Worker"
    echo ""
    stop_worker_type "upload" "Upload Worker"
    echo ""
    
    print_success "所有 workers 已停止"
}

# 启动指定类型的 worker
start_worker_type() {
    local worker_type=$1
    local worker_name=$2
    local log_file=$3
    
    # 检查是否已运行
    if is_worker_running "$worker_type"; then
        local pid=$(get_worker_pid "$worker_type")
        print_error "$worker_name 已在运行 (PID: $pid)"
        return 1
    fi
    
    print_info "正在启动 $worker_name..."
    
    # 在后台运行，日志输出到独立文件
    nohup uv run python "${worker_type}_worker.py" >> "$log_file" 2>&1 &
    local pid=$!
    
    # 等待短暂时间，检查进程是否成功启动
    sleep 1
    
    if kill -0 "$pid" 2>/dev/null; then
        # 保存 PID 到文件
        echo "$pid" > "$PID_DIR/${worker_type}_worker.pid"
        print_success "$worker_name 已启动 (PID: $pid)"
        return 0
    else
        print_error "$worker_name 启动失败，请查看日志: tail -f $log_file"
        return 1
    fi
}

# 启动 Worker 进程
start_workers() {
    ensure_directories
    
    print_header "=========================================="
    print_header " 启动 Workers"
    print_header "=========================================="
    echo ""
    
    # 启动 Process Worker
    print_header "--- Process Worker ---"
    start_worker_type "process" "Process Worker" "$PROCESS_WORKER_LOG"
    local process_result=$?
    echo ""
    
    # 启动 Upload Worker
    print_header "--- Upload Worker ---"
    start_worker_type "upload" "Upload Worker" "$UPLOAD_WORKER_LOG"
    local upload_result=$?
    echo ""
    
    # 总结
    print_header "=========================================="
    if [ $process_result -eq 0 ] && [ $upload_result -eq 0 ]; then
        print_success "所有 workers 启动成功!"
    else
        print_warning "部分 workers 启动失败，请检查日志"
    fi
    
    echo ""
    print_info "查看日志:"
    echo "   Process Worker: tail -f $PROCESS_WORKER_LOG"
    echo "   Upload Worker:  tail -f $UPLOAD_WORKER_LOG"
    print_info "查看状态: $0 status"
}

# 显示 Worker 状态
show_status() {
    print_header "=========================================="
    print_header " Worker 状态"
    print_header "=========================================="
    echo ""
    
    # Process Worker 状态
    print_header "⚙️  Process Worker:"
    get_worker_status "process"
    echo ""
    
    # Upload Worker 状态
    print_header "📤 Upload Worker:"
    get_worker_status "upload"
    echo ""
    
    print_header "=========================================="
}

# 查看日志
show_logs() {
    local worker_type=$1
    local lines=${2:-50}
    
    case "$worker_type" in
        process)
            local log_file="$PROCESS_WORKER_LOG"
            local worker_name="Process Worker"
            ;;
        upload)
            local log_file="$UPLOAD_WORKER_LOG"
            local worker_name="Upload Worker"
            ;;
        *)
            print_error "未知的 worker 类型: $worker_type"
            print_info "可用类型: process, upload"
            return 1
            ;;
    esac
    
    if [ ! -f "$log_file" ]; then
        print_error "日志文件不存在: $log_file"
        return 1
    fi
    
    print_header "=========================================="
    print_header " $worker_name - 最近 $lines 行日志"
    print_header "=========================================="
    echo ""
    tail -n "$lines" "$log_file"
    echo ""
    print_info "实时查看: tail -f $log_file"
}

# 跟踪日志
tail_logs() {
    local worker_type=$1
    
    case "$worker_type" in
        process)
            local log_file="$PROCESS_WORKER_LOG"
            local worker_name="Process Worker"
            ;;
        upload)
            local log_file="$UPLOAD_WORKER_LOG"
            local worker_name="Upload Worker"
            ;;
        *)
            print_error "未知的 worker 类型: $worker_type"
            print_info "可用类型: process, upload"
            return 1
            ;;
    esac
    
    if [ ! -f "$log_file" ]; then
        print_error "日志文件不存在: $log_file"
        return 1
    fi
    
    print_info "$worker_name 实时日志 (Ctrl+C 退出):"
    echo ""
    tail -f "$log_file"
}

# 清理日志
cleanup_logs() {
    print_info "正在清理 worker 日志..."
    
    if [ -f "$PROCESS_WORKER_LOG" ]; then
        > "$PROCESS_WORKER_LOG"
        print_success "已清空 Process Worker 日志"
    fi
    
    if [ -f "$UPLOAD_WORKER_LOG" ]; then
        > "$UPLOAD_WORKER_LOG"
        print_success "已清空 Upload Worker 日志"
    fi
    
    # 清理 PID 文件
    if [ -d "$PID_DIR" ]; then
        rm -f "$PID_DIR"/*.pid 2>/dev/null || true
        print_success "已清理 PID 文件"
    fi
    
    print_success "清理完成"
}

# 显示使用说明
show_help() {
    cat << EOF
========================================
 Worker 进程管理脚本（单进程版本）
========================================

用法: $0 <command> [options]

命令:
  start          启动所有 workers (1 Process Worker + 1 Upload Worker)
  
  stop           停止所有 workers
  
  restart        重启所有 workers
  
  status         查看 workers 状态
  
  logs <type> [N] 查看指定类型 worker 的最近 N 行日志
                  type: process 或 upload
                  N: 行数 (默认: 50)
  
  tail <type>    实时跟踪指定类型 worker 的日志
                 type: process 或 upload
  
  cleanup        清理日志和临时文件
  
  help           显示此帮助信息

示例:
  $0 start                # 启动所有 workers
  $0 stop                 # 停止所有 workers
  $0 restart              # 重启所有 workers
  $0 status               # 查看状态
  $0 logs process 100     # 查看 Process Worker 最近 100 行日志
  $0 tail upload          # 实时查看 Upload Worker 日志
  $0 cleanup              # 清理日志

配置:
  日志目录: $LOG_DIR
  Process Worker 日志: $PROCESS_WORKER_LOG
  Upload Worker 日志:  $UPLOAD_WORKER_LOG
  PID 目录: $PID_DIR

========================================
EOF
}

# --- 主逻辑 ---

COMMAND=${1:-help}

case "$COMMAND" in
    start)
        start_workers
        ;;
    stop)
        stop_workers
        ;;
    restart)
        echo ""
        print_info "========== 重启 Workers =========="
        echo ""
        stop_workers
        sleep 2
        echo ""
        start_workers
        echo ""
        print_success "========== 重启完成 =========="
        ;;
    status)
        show_status
        ;;
    logs)
        if [ -z "$2" ]; then
            print_error "请指定 worker 类型 (process 或 upload)"
            echo ""
            show_help
            exit 1
        fi
        show_logs "$2" "${3:-50}"
        ;;
    tail)
        if [ -z "$2" ]; then
            print_error "请指定 worker 类型 (process 或 upload)"
            echo ""
            show_help
            exit 1
        fi
        tail_logs "$2"
        ;;
    cleanup)
        cleanup_logs
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
