#!/bin/bash
# ========================================
# Worker 进程管理脚本
# 功能: 启动, 停止, 重启, 状态查看
# ========================================

set -e  # 遇到错误立即退出

# --- 配置变量 ---
DEFAULT_PROCESS_WORKERS=1
DEFAULT_UPLOAD_WORKERS=1
LOG_DIR="logs"
PID_DIR=".pids"
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

# 获取所有 worker PIDs
get_worker_pids() {
    local worker_type=$1
    pgrep -f "uv run python ${worker_type}_worker.py" 2>/dev/null || true
}

# 检查 worker 是否运行
is_worker_running() {
    local worker_type=$1
    local pids=$(get_worker_pids "$worker_type")
    [ -n "$pids" ]
}

# 获取 worker 运行数量
get_worker_count() {
    local worker_type=$1
    local pids=$(get_worker_pids "$worker_type")
    if [ -n "$pids" ]; then
        echo "$pids" | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# 获取 worker 状态信息
get_worker_status() {
    local worker_type=$1
    local pids=$(get_worker_pids "$worker_type")
    
    if [ -z "$pids" ]; then
        echo "   未运行"
        return
    fi
    
    echo "   运行中 - 数量: $(echo "$pids" | wc -l | tr -d ' ')"
    echo "   PIDs: $pids"
    
    # 显示每个进程的详细信息
    echo "$pids" | while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
            local cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
            local mem=$(ps -o %mem= -p "$pid" 2>/dev/null | tr -d ' ')
            echo "     ├─ PID $pid: 运行 $uptime | CPU: ${cpu}% | 内存: ${mem}%"
        fi
    done
}

# --- 主要功能函数 ---

# 停止指定类型的 workers
stop_worker_type() {
    local worker_type=$1
    local worker_name=$2
    
    local pids=$(get_worker_pids "$worker_type")
    
    if [ -z "$pids" ]; then
        print_warning "$worker_name 未运行"
        return 0
    fi
    
    print_info "正在停止 $worker_name (PIDs: $pids)..."
    
    # 发送 SIGTERM 信号
    echo "$pids" | xargs kill -TERM 2>/dev/null || true
    
    # 等待进程优雅退出（最多 5 秒）
    local count=0
    while [ $count -lt 5 ]; do
        local remaining=$(get_worker_pids "$worker_type")
        if [ -z "$remaining" ]; then
            print_success "$worker_name 已停止"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    # 如果进程仍未退出，强制杀死
    local remaining=$(get_worker_pids "$worker_type")
    if [ -n "$remaining" ]; then
        print_warning "部分进程未响应 SIGTERM，强制终止..."
        echo "$remaining" | xargs kill -9 2>/dev/null || true
        sleep 1
        
        remaining=$(get_worker_pids "$worker_type")
        if [ -z "$remaining" ]; then
            print_success "$worker_name 已强制停止"
        else
            print_error "无法停止部分 $worker_name 进程: $remaining"
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
    
    stop_worker_type "process" "Process Workers"
    echo ""
    stop_worker_type "upload" "Upload Workers"
    echo ""
    
    # 清理 PID 目录
    if [ -d "$PID_DIR" ]; then
        rm -f "$PID_DIR"/*.pid 2>/dev/null || true
    fi
    
    print_success "所有 workers 已停止"
}

# 启动指定类型的 worker
start_worker_type() {
    local worker_type=$1
    local worker_count=$2
    local worker_name=$3
    local log_file=$4
    
    print_info "启动 $worker_count 个 $worker_name..."
    
    local success_count=0
    for i in $(seq 1 $worker_count); do
        # 在后台运行，日志输出到独立文件
        nohup uv run python "${worker_type}_worker.py" >> "$log_file" 2>&1 &
        local pid=$!
        
        # 等待短暂时间，检查进程是否成功启动
        sleep 0.5
        
        if kill -0 "$pid" 2>/dev/null; then
            # 保存 PID 到文件
            echo "$pid" >> "$PID_DIR/${worker_type}_worker.pids"
            print_success "$worker_name #$i 已启动 (PID: $pid)"
            success_count=$((success_count + 1))
        else
            print_error "$worker_name #$i 启动失败"
        fi
    done
    
    if [ $success_count -eq $worker_count ]; then
        print_success "所有 $worker_name 启动成功 ($success_count/$worker_count)"
        return 0
    elif [ $success_count -gt 0 ]; then
        print_warning "部分 $worker_name 启动成功 ($success_count/$worker_count)"
        return 1
    else
        print_error "所有 $worker_name 启动失败"
        return 1
    fi
}

# 启动 Worker 进程
start_workers() {
    local PROCESS_WORKERS=$1
    local UPLOAD_WORKERS=$2
    
    ensure_directories
    
    print_header "=========================================="
    print_header " 启动 Workers"
    print_header "=========================================="
    echo ""
    
    print_info "配置:"
    echo "   Process Workers: $PROCESS_WORKERS"
    echo "   Upload Workers:  $UPLOAD_WORKERS"
    echo ""
    
    # 检查是否已有 worker 在运行
    if is_worker_running "process"; then
        print_warning "检测到 Process Workers 已在运行"
        print_info "当前运行数量: $(get_worker_count process)"
        print_info "使用 '$0 stop' 先停止现有进程"
        echo ""
    fi
    
    if is_worker_running "upload"; then
        print_warning "检测到 Upload Workers 已在运行"
        print_info "当前运行数量: $(get_worker_count upload)"
        print_info "使用 '$0 stop' 先停止现有进程"
        echo ""
    fi
    
    # 清理旧的 PID 文件
    rm -f "$PID_DIR"/*.pids 2>/dev/null || true
    
    # 启动 Process Workers
    print_header "--- Process Workers ---"
    start_worker_type "process" "$PROCESS_WORKERS" "Process Worker" "$PROCESS_WORKER_LOG"
    local process_result=$?
    echo ""
    
    # 启动 Upload Workers
    print_header "--- Upload Workers ---"
    start_worker_type "upload" "$UPLOAD_WORKERS" "Upload Worker" "$UPLOAD_WORKER_LOG"
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
    print_info "总计: $(get_worker_count process) Process Workers + $(get_worker_count upload) Upload Workers"
    print_info "查看日志:"
    echo "   Process Workers: tail -f $PROCESS_WORKER_LOG"
    echo "   Upload Workers:  tail -f $UPLOAD_WORKER_LOG"
    print_info "查看状态: $0 status"
}

# 显示 Worker 状态
show_status() {
    print_header "=========================================="
    print_header " Worker 状态"
    print_header "=========================================="
    echo ""
    
    # Process Workers 状态
    print_header "⚙️  Process Workers:"
    get_worker_status "process"
    echo ""
    
    # Upload Workers 状态
    print_header "📤 Upload Workers:"
    get_worker_status "upload"
    echo ""
    
    # 总计
    local total_count=$(($(get_worker_count process) + $(get_worker_count upload)))
    print_header "=========================================="
    print_info "总计运行中的 workers: $total_count"
    print_header "=========================================="
}

# 查看日志
show_logs() {
    local worker_type=$1
    local lines=${2:-50}
    
    case "$worker_type" in
        process)
            local log_file="$PROCESS_WORKER_LOG"
            local worker_name="Process Workers"
            ;;
        upload)
            local log_file="$UPLOAD_WORKER_LOG"
            local worker_name="Upload Workers"
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
            local worker_name="Process Workers"
            ;;
        upload)
            local log_file="$UPLOAD_WORKER_LOG"
            local worker_name="Upload Workers"
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
        rm -f "$PID_DIR"/*.pids 2>/dev/null || true
        print_success "已清理 PID 文件"
    fi
    
    print_success "清理完成"
}

# 显示使用说明
show_help() {
    cat << EOF
========================================
 Worker 进程管理脚本
========================================

用法: $0 <command> [options]

命令:
  start [P] [U]  启动 workers
                 P = Process Workers 数量 (默认: $DEFAULT_PROCESS_WORKERS)
                 U = Upload Workers 数量  (默认: $DEFAULT_UPLOAD_WORKERS)
  
  stop           停止所有 workers
  
  restart [P] [U] 重启所有 workers
  
  status         查看 workers 状态
  
  logs <type> [N] 查看指定类型 worker 的最近 N 行日志
                  type: process 或 upload
                  N: 行数 (默认: 50)
  
  tail <type>    实时跟踪指定类型 worker 的日志
                 type: process 或 upload
  
  cleanup        清理日志和临时文件
  
  help           显示此帮助信息

示例:
  $0 start                    # 使用默认配置启动 (1 Process + 1 Upload)
  $0 start 4 2                # 启动 4 个 Process Workers 和 2 个 Upload Workers
  $0 stop                     # 停止所有 workers
  $0 restart 2 1              # 重启，使用 2 个 Process 和 1 个 Upload
  $0 status                   # 查看状态
  $0 logs process 100         # 查看 Process Workers 最近 100 行日志
  $0 tail upload              # 实时查看 Upload Workers 日志
  $0 cleanup                  # 清理日志

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
        P_COUNT=${2:-$DEFAULT_PROCESS_WORKERS}
        U_COUNT=${3:-$DEFAULT_UPLOAD_WORKERS}
        start_workers "$P_COUNT" "$U_COUNT"
        ;;
    stop)
        stop_workers
        ;;
    restart)
        P_COUNT=${2:-$DEFAULT_PROCESS_WORKERS}
        U_COUNT=${3:-$DEFAULT_UPLOAD_WORKERS}
        echo ""
        print_info "========== 重启 Workers =========="
        echo ""
        stop_workers
        sleep 2
        echo ""
        start_workers "$P_COUNT" "$U_COUNT"
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
