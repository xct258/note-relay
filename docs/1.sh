#!/bin/bash

# 设置工作目录
source_backup="/rec"
config_file="${source_backup}/config.conf"
script_dir="${source_backup}/脚本"

# 读取配置文件
source "$config_file"

# 引入日志函数库
source "${script_dir}/log.sh"
# 日志记录路径
LOG_BASE_DIR="${source_backup}/logs"
# 日志记录名称
LOG_APP_NAME="上传备份脚本"

# 脚本开始执行的时间轴
SCRIPT_START_TS=$(date +%s)

# 日志记录
log info "═══════════════════════════════════════════════"
log info "脚本开始执行"
log info "═══════════════════════════════════════════════"

# 记录磁盘空间与关键配置状态
log info "==================== 运行环境状态 ===================="
log info "💾 磁盘空间 | $(df -Ph "$source_backup" 2>/dev/null | awk 'NR==2{printf "总量: %s ｜ 已用: %s ｜ 可用: %s ｜ 使用率: %s", $2, $3, $4, $5}')"
log info "⚙️ 核心配置 | 弹幕压制: [${ENABLE_DANMAKU_OVERLAY:-false}]  视频上传: [${ENABLE_VIDEO_UPLOAD:-false}]"
log info "⚙️ 核心配置 | 网盘备份: [${ENABLE_RCLONE_UPLOAD:-false}]  FLV转换: [${CONVERT_FLV_TO_MP4:-false}]"
log info "⚙️ 清理策略 | 自动清理: [${ENABLE_CLEANUP:-false}]  保留天数: [${RETENTION_DAYS:-3}天]"
log info "======================================================"

# 检查 source_folders 中的文件夹是否存在，不存在则创建,防止脚本报错
for source_folder in "${source_folders[@]}"; do
  if [ ! -d "$source_folder" ]; then
    mkdir -p "$source_folder"
  fi
done

# 创建一个空数组来保存非空目录
directories=()
# 创建一个空数组来保存所有的备份目录
cache_dirs=()

# 查找指定视频文件夹下的非空目录
while IFS= read -r -d '' dir; do
  if ! find "$dir" -mindepth 2 -type d -print -quit 2>/dev/null | grep -q .; then
    directories+=("$dir")
  fi
done < <(find "${source_folders[@]}" -type d -not -empty -print0 2>/dev/null)

# 如果没有待处理文件夹，直接进入后续维护逻辑
if [[ ${#directories[@]} -eq 0 ]]; then
  log info "未发现待处理的目录"
else
  log info "开始处理${#directories[@]}个目录"
  # 遍历每个非空目录
  for dir in "${directories[@]}"; do
    # 日志记录
    log info "处理目录$(basename "$dir")"
    # 统计当前目录下即将被清理的日志文件数量（包含 .txt, .log 等）
    log_count=$(find "$dir" -type f \( -iname "*.txt" -o -iname "*.log" \) 2>/dev/null | wc -l)
    # 根据统计数量动态打印日志并执行清理
    if [ "$log_count" -gt 0 ]; then
      # 获取所有匹配的日志文件名（纯文件名，不带路径），用“、”号拼接并去掉末尾的标点
      log_files=$(find "$dir" -type f \( -iname "*.txt" -o -iname "*.log" \) -printf "%f、" 2>/dev/null | sed 's/、$//')
      log info "发现${log_count}个日志文件，正在清理..."
      # 执行删除
      find "$dir" -type f \( -iname "*.txt" -o -iname "*.log" \) -delete 2>/dev/null
    fi
    # 取最早的文件提取元数据（用于确定缓存目录名）
    first_file=$(find "$dir" -type f \( -name "*.mp4" -o -name "*.flv" \) -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
    if [[ -z "$first_file" ]]; then
      log info "目录 ${dir} 中无视频文件，直接移除"
      rm -rf "$dir"
      continue
    fi
    # 提取文件名称，不带路径
    base_filename=$(basename "$first_file")
    # 从文件夹名称中提取开播时间
    start_time=$(echo "$base_filename" | cut -d '_' -f 2 | cut -d '.' -f 1)
    # 从文件名称中提取主播名称
    streamer_name=$(echo "$base_filename" | sed -E 's/.*_(.*)\..*/\1/')
    # 转换名称
    [[ "$streamer_name" == "高机动持盾军官" ]] && streamer_name="括弧笑bilibili"
    # 获取前缀
    recording_platform=$(echo "$base_filename" | cut -d'_' -f 1 | sed 's/^投稿版-//')
    # 创建缓存目录，立即将源目录所有文件整体移入
    cache_dir="${source_backup}/正在处理中/${streamer_name}/${start_time}"
    mkdir -p "$cache_dir"
    # 记录日志
    log info "将${dir}所有文件移动到临时目录${cache_dir}"
    while IFS= read -r -d '' f; do
      mv "$f" "$cache_dir/"
    done < <(find "$dir" -type f -print0 2>/dev/null)
    # 清理空文件夹
    rmdir "$dir"
  
    # 将所有临时文件目录存入数组
    cache_dirs+=("$cache_dir")
    
    # 1. 第一次扫描：将所有文件读入临时数组
    mapfile -d '' -t temp_files < <(find "$cache_dir" -type f \( -name "*.flv" -o -name "*.mp4" -o -name "*.xml" \) -print0 | sort -z)
    if [[ ${#temp_files[@]} -eq 0 ]]; then
      log info "缓存目录 ${cache_dir} 中无任何文件，跳过"
      continue
    fi
    input_files=() 
    # 2. 循环遍历临时数组
    for file in "${temp_files[@]}"; do
      # 防错：如果文件已经被前面的循环联动删除了，直接跳过
      [[ ! -f "$file" ]] && continue
      # 基础路径和对应的视频/XML路径
      base_path="${file%.*}"
      # 寻找这个文件关联的视频路径（无论当前处理的是视频还是 XML，都找出其对应的视频本体）
      ext="${file##*.}"
      if [[ "$ext" == "xml" ]]; then
         # 如果当前是 XML，推测它的视频本体可能是 .mp4 或 .flv
         if [[ -f "${base_path}.mp4" ]]; then vid_file="${base_path}.mp4";
         elif [[ -f "${base_path}.flv" ]]; then vid_file="${base_path}.flv";
         else vid_file=""; fi
      else
         vid_file="$file" # 如果当前本来就是视频，那本体就是自己
      fi
      # 3. 核心判断：如果视频本体存在，检查它的大小
      if [[ -n "$vid_file" ]]; then
        vsize=$(stat -c%s "$vid_file" 2>/dev/null || echo 0)
        if [[ $vsize -lt 10485760 ]]; then # 小于 10MB
          # 发现垃圾视频，把视频和对应的 XML 一起在硬盘上干掉
          log info "关联视频过小 (<10MB)，清理该组文件: $base_path.*"
          rm -f "${base_path}.mp4" "${base_path}.flv" "${base_path}.xml"
          continue # 拒绝让任何一个进篮子
        fi
      else
        # 如果当前是个 XML，且在硬盘上根本找不到对应的视频本体，说明是孤儿 XML
        if [[ "$ext" == "xml" ]]; then
          log info "发现无视频关联的孤儿 XML，执行清理: $file"
          rm -f "$file"
          continue
        fi
      fi
      # 4. 只有本体大于 10MB 的安全文件，才能进入合格品篮子
      input_files+=("$file") 
    done
    # 5. 最终精准判断
    if [[ ${#input_files[@]} -eq 0 ]]; then
      log info "清理小文件后，${cache_dir} 中已无有效视频，跳过"
      continue
    fi
    log info "真正剩余有效文件 ${#input_files[@]} 个"

    # 处理有效的大视频和 XML 的转换
    for file in "${input_files[@]}"; do
      [[ ! -f "$file" ]] && continue
      ext="${file##*.}"
      filename="$(basename "$file" ."$ext")"
      fsize=$(stat -c%s "$file" 2>/dev/null || echo 0)
      case "$ext" in
        xml|mp4)
          log info "保留文件: $file (大小:$(format_size $fsize) 类型:$ext)"
          ;;
        flv)
          if [[ "$CONVERT_FLV_TO_MP4" != "true" && "$ENABLE_DANMAKU_OVERLAY" != "true" ]]; then
            log info "配置禁用 flv 转换，保留原文件: $file (大小:$(format_size $fsize))"
            continue
          fi
          output_file="$cache_dir/${filename}.mp4"
          log info "转换视频: $(basename "$file") (大小:$(format_size $fsize)) -> $(basename "$output_file")"
          # 1. 兼容性改造：记录开始时间戳（秒级保底，兼容所有精简系统）
          START_RAW=$(date +%s%N 2>/dev/null)
          if [[ "$START_RAW" == *N ]]; then
            # 说明系统不支持 %N，退回到普通秒级计数
            CONV_START_TS=$(date +%s)
            TIME_UNIT="s"
          else
            CONV_START_TS=$(( START_RAW / 1000000 )) # 转换为毫秒
            TIME_UNIT="ms"
          fi
          # 2. ffmpeg 引入 -fflags +genpts，彻底杜绝音画不同步和首帧黑屏错误
          if ffmpeg -fflags +genpts -i "$file" -c:v copy -c:a copy -loglevel error -y "$output_file"; then
            # 3. 耗时计算安全保底
            END_RAW=$(date +%s%N 2>/dev/null)
            if [[ "$TIME_UNIT" == "s" ]]; then
                CONV_ELAPSED=$(( $(date +%s) - CONV_START_TS ))
            else
                CONV_ELAPSED=$(( (END_RAW / 1000000) - CONV_START_TS ))
            fi
            out_size=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
            rm -f "$file"
            log success "转换成功（耗时:${CONV_ELAPSED}${TIME_UNIT} 输出大小:$(format_size $out_size)），已清理源文件"
          else
            END_RAW=$(date +%s%N 2>/dev/null)
            if [[ "$TIME_UNIT" == "s" ]]; then
                CONV_ELAPSED=$(( $(date +%s) - CONV_START_TS ))
            else
                CONV_ELAPSED=$(( (END_RAW / 1000000) - CONV_START_TS ))
            fi
            log error "转换失败（耗时:${CONV_ELAPSED}${TIME_UNIT}）：$file，保留原视频"
          fi
        ;;
      esac
    done
  done
fi

# 检查是否有需要备份/上传的目录
if [[ ${#cache_dirs[@]} -eq 0 ]]; then
  log info "无新生成的备份目录需要处理"
else
  log info "共 ${#cache_dirs[@]} 个备份目录待处理"
  for cache_dir in "${cache_dirs[@]}"; do
    [[ -z "$cache_dir" ]] && continue
    log info "处理备份目录: $(basename "$cache_dir")"
    log info "完整路径: ${cache_dir}"

    # 声明数组，用于存储上视频的文件名
    compressed_files=()
    original_files=()
    audio_files=()

    # 处理从临时目录获取的文件路径
    mapfile -d '' -t input_files < <(find "$cache_dir" -type f -print0 | sort -z)

    # 获取临时目录第一个文件的信息，用于提取直播开始时间和主播名称
    first_file="${input_files[0]}"
    # 示例：video/高机动持盾军官/录播姬_2024年12月01日22点13分11秒_暗区最穷_高机动持盾军官.flv
    # 去除文件路径
    base_filename=$(basename "$first_file")
    # 示例：录播姬_2024年12月01日22点13分11秒_暗区最穷_高机动持盾军官.flv
    # 获取开播时间
    start_time=$(echo "$base_filename" | cut -d '_' -f 2 | cut -d '.' -f 1)
    # 示例：2024年12月01日22点13分11秒
    # 处理开播时间格式
    formatted_start_time_1=$(echo "$start_time" | sed 's/^\(.*点\).*/\1/')
    # 示例：2024年12月01日22点
    formatted_start_time_2=$(echo "$start_time" | sed 's/日/日 /')
    # 示例：2024年12月01日 22点13分11秒
    formatted_start_time_3=$(echo "$start_time" | sed -E 's/([0-9]{4})年([0-9]{2})月([0-9]{2})日.*/\1\/\2\/\1-\2-\3/') 
    # 示例：2024/12/2024-12-01
    formatted_start_time_4=$(echo "$start_time" | sed 's/日.*/日/')
    # 示例：2024年12月01日
    # 获取直播间标题
    stream_title=$(echo "$base_filename" | awk -F'_' '{for (i=3; i<NF-1; i++) printf "%s_", $i; printf "%s\n", $(NF-1)}')
    # 示例：暗区最穷
    # 获取录制平台
    recording_platform=$(echo "$base_filename" | cut -d'_' -f 1 | sed 's/^投稿版-//')
    # 示例：录播姬
    # 获取主播名称
    streamer_name=$(echo "$base_filename" | sed -E 's/.*_(.*)\..*/\1/')
    # 转换主播名称
    if [[ "$streamer_name" == "高机动持盾军官" ]]; then
      streamer_name="括弧笑bilibili"
    fi

    log info "直播标题: $stream_title"
    log info "录制平台: $recording_platform"
    log info "主播名称: $streamer_name"
    log info "开播时间: $start_time"
    log info "上传标题: ${formatted_start_time_4} [${stream_title}]"
    
    # 循环处理文件夹中的每一个文件
    for video_file in "${input_files[@]}"; do
      # 检测这个文件是否为存在
      if [[ -f "$video_file" ]]; then
        # 获取文件名（不带路径）
        filename=$(basename "$video_file")
        # 示例：录播姬_2024年12月01日22点13分11秒_暗区最穷_高机动持盾军官.flv

        # 获取文件名（不带扩展名）
        filename_no_ext="${filename%.*}"
        # 示例：录播姬_2024年12月01日22点13分11秒_暗区最穷_高机动持盾军官
        # 检测直播名称和需要处理的平台
        if [[ "$streamer_name" == "括弧笑bilibili" && " ${update_servers[*]} " == *" $recording_platform "* ]]; then
          # 获取文件扩展名
          ext="${filename##*.}"
          # 如果文件扩展名不等于mp4并且不等于flv则跳过循环
          [[ "$ext" != "mp4" && "$ext" != "flv" ]] && continue
          # 如果文件以投稿版开头则说明文件已经是压制版，跳过压制
          if [[ "$filename" == 投稿版-* ]]; then
            log info "检测到投稿版视频，跳过弹幕压制"
            # 直接将视频加入到数组
            compressed_files+=("${cache_dir}/${filename}")
            original_files+=("${cache_dir}/${filename}")
          else
            # 如果不是投稿版开头则先将原始视频加入到数组
            original_files+=("${cache_dir}/${filename}")
            # 拼接文件名称
            xml_file="${filename_no_ext}.xml"
            ass_file="${filename_no_ext}.ass"
            output_file="投稿版-${filename_no_ext}.mp4"