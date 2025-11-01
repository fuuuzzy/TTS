#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TTS 语音生成工具

从文本文件读取内容，使用 TTS 模型生成指定语言的语音。
支持使用音频样本作为参考进行语音克隆。
"""

import argparse
import os
import sys
from pathlib import Path
from typing import Optional, Any

# 自动同意 Coqui TTS 服务条款（用于 XTTS v2 等模型）
os.environ['COQUI_TOS_AGREED'] = '1'

from TTS.api import TTS


def get_reference_audio(audio_path: str, logger: Optional[Any] = None) -> str:
    """
    获取参考音频文件路径并验证其存在
    
    Args:
        audio_path: 音频文件路径
        logger: 日志记录器（可选）
    
    Returns:
        参考音频文件路径
    """
    path = Path(audio_path)
    if not path.exists():
        raise FileNotFoundError(f"音频文件不存在: {path}")

    # 支持的音频格式
    audio_extensions = {'.wav', '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus'}
    file_ext = path.suffix.lower()

    # 定义输出函数
    def log_info(msg: str):
        if logger:
            logger.info(msg)
        else:
            print(msg)

    # 验证是否为音频文件
    if file_ext in audio_extensions:
        log_info(f"🎵 使用音频文件: {path}")
        return str(path)

    # 未知格式，尝试作为音频文件处理
    log_info(f"⚠️  未知文件格式 ({file_ext})，尝试作为音频文件使用: {path}")
    return str(path)


def get_text_from_input(input_str: str) -> str:
    """
    从输入获取文本，支持文件路径或直接文本
    
    Args:
        input_str: 文件路径或直接文本内容
    
    Returns:
        文本内容
    """
    input_path = Path(input_str)

    # 如果输入是存在的文件路径，则从文件读取
    if input_path.exists() and input_path.is_file():
        # 注意：get_text_from_input 没有 logger 参数，保持 print
        print(f"📄 检测到文件路径，正在读取: {input_path}")
        for encoding in ('utf-8', 'gbk'):
            try:
                with open(input_path, 'r', encoding=encoding) as f:
                    text = f.read().strip()
                if not text:
                    raise ValueError(f"文本文件为空: {input_path}")
                return text
            except UnicodeDecodeError:
                continue
        raise ValueError(f"无法读取文本文件，请确保文件使用 UTF-8 或 GBK 编码: {input_path}")
    else:
        # 否则直接作为文本使用
        text = input_str.strip()
        if not text:
            raise ValueError("输入的文本不能为空")
        return text


def get_available_models_by_language(language: str) -> list:
    """
    使用 TTS API 动态查询指定语言的可用模型
    
    Args:
        language: 语言代码（如 'en', 'zh', 'ja', 'es' 等）
    
    Returns:
        list: 该语言的可用模型列表，格式为 ['tts_models/lang/dataset/model', ...]
    """
    try:
        from TTS.api import TTS
        tts = TTS()
        manager = tts.list_models()
        all_models = manager.list_tts_models()

        # 查找匹配语言的模型
        lang_lower = language.lower()
        # 语言代码映射（标准化）
        lang_map = {
            'zh': 'zh-CN',
            'chinese': 'zh-CN',
            'cn': 'zh-CN',
        }
        normalized_lang = lang_map.get(lang_lower, lang_lower)

        # 过滤出该语言的模型
        matching_models = [
            model for model in all_models
            if isinstance(model, str) and f'/{normalized_lang}/' in model or f'/{lang_lower}/' in model
        ]

        return matching_models if matching_models else []
    except Exception:
        return []


def select_model(language: str, prefer_multilingual: bool = False) -> str:
    """
    根据语言自动选择模型
    
    策略：
    1. 如果 prefer_multilingual=True，直接返回 XTTS v2 多语言模型
    2. 否则，优先使用经过验证的稳定单语言模型
    3. 对于已知有问题的模型（如 ja/kokoro），使用 XTTS v2
    4. 如果没有单语言模型，回退到 XTTS v2
    
    Args:
        language: 语言代码（如 'en', 'zh', 'ja' 等）
        prefer_multilingual: 是否优先使用多语言模型（默认 False）
    
    Returns:

        str: 模型名称
    """
    # 如果明确要求使用多语言模型
    if prefer_multilingual:
        return 'tts_models/multilingual/multi-dataset/xtts_v2'

    lang_lower = language.lower()

    # 经过验证的稳定单语言模型（已知可以正常工作）
    stable_single_lang_models = {
        # 中文 - 稳定
        'zh': "tts_models/zh-CN/baker/tacotron2-DDC-GST",
        'ja': "'tts_models/ja/kokoro/tacotron2-DDC'",
        'chinese': "tts_models/zh-CN/baker/tacotron2-DDC-GST",
        'cn': "tts_models/zh-CN/baker/tacotron2-DDC-GST",
        'zh-cn': "tts_models/zh-CN/baker/tacotron2-DDC-GST",
        # 英文 - 稳定
        'en': "tts_models/en/ljspeech/tacotron2-DDC",
        'english': "tts_models/en/ljspeech/tacotron2-DDC",
        # 法语 - 稳定
        'fr': "tts_models/fr/mai/tacotron2-DDC",
        'french': "tts_models/fr/mai/tacotron2-DDC",
        # 德语 - 稳定
        'de': "tts_models/de/thorsten/tacotron2-DDC",
        'german': "tts_models/de/thorsten/tacotron2-DDC",
        # 西班牙语 - 稳定
        'es': "tts_models/es/mai/tacotron2-DDC",
        'spanish': "tts_models/es/mai/tacotron2-DDC",
        'español': "tts_models/es/mai/tacotron2-DDC",
    }

    # 已知有问题的语言（模型文件不完整或下载失败），直接使用 XTTS v2
    problematic_languages = {
        'ja', 'japanese',  # kokoro 模型有文件缺失问题
    }

    # 如果是已知有问题的语言，使用 XTTS v2
    if lang_lower in problematic_languages:
        return 'tts_models/multilingual/multi-dataset/xtts_v2'

    # 如果有稳定的单语言模型，使用它
    if lang_lower in stable_single_lang_models:
        return stable_single_lang_models[lang_lower]

    # 否则，回退到 XTTS v2 多语言模型
    return 'tts_models/multilingual/multi-dataset/xtts_v2'


def generate_speech(
        input_text: str,
        language: str,
        video_sample: Optional[str] = None,
        model_name: Optional[str] = None,
        output_path: Optional[str] = None,
        device: str = "cpu",
        prefer_multilingual: bool = False,
        logger: Optional[Any] = None
) -> str:
    """
    从文本生成语音（支持文件路径或直接文本）
    
    Args:
        input_text: 输入文本或文本文件路径
        language: 目标语言代码（如 'en', 'zh', 'fr' 等）
        video_sample: 视频样本路径（用于提取参考音频进行语音克隆）
        model_name: TTS 模型名称，如果为 None 则自动选择
        output_path: 输出音频文件路径，如果为 None 则自动生成
        device: 设备类型，'cpu' 或 'cuda'
        prefer_multilingual: 是否优先使用多语言模型（默认 False）
        logger: 日志记录器（可选），如果提供则使用日志输出，否则使用 print
    
    Returns:
        输出音频文件路径
    """

    # 定义输出函数：如果有 logger 则使用 logger，否则使用 print
    def log_info(msg: str):
        if logger:
            logger.info(msg)
        else:
            print(msg)

    def log_error(msg: str):
        if logger:
            logger.error(msg)
        else:
            print(msg)

    def log_warning(msg: str):
        if logger:
            logger.warning(msg)
        else:
            print(msg)

    # 获取文本内容（自动识别是文件还是直接文本）
    try:
        text = get_text_from_input(input_text)
        log_info(f"✅ 文本准备完成，共 {len(text)} 个字符")
    except Exception as e:
        log_error(f"❌ 获取文本失败: {e}")
        raise

    # 确定输出路径
    if output_path is None:
        # 如果输入是文件路径，基于文件名生成输出
        input_path = Path(input_text)
        if input_path.exists() and input_path.is_file():
            output_path = str(input_path.parent / f"{input_path.stem}_tts_{language}.wav")
        else:
            # 如果是直接文本，生成默认文件名
            from datetime import datetime
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_path = f"output_tts_{language}_{timestamp}.wav"
    else:
        output_path = str(Path(output_path))

    # 获取参考音频（仅支持音频文件）
    reference_audio = None
    if video_sample:
        try:
            reference_audio = get_reference_audio(video_sample, logger=logger)
            log_info(f"✅ 参考音频准备完成")
        except Exception as e:
            log_error(f"❌ 获取参考音频失败: {e}")
            raise

    # 初始化 TTS 模型
    if model_name is None:
        get_available_models_by_language(language)
        model_name = select_model(language, prefer_multilingual=prefer_multilingual)

    log_info(f"🤖 正在初始化 TTS 模型: {model_name}")
    try:
        tts = TTS(model_name=model_name, progress_bar=True)
        log_info("📥 模型加载中...")
        tts.to(device)
        log_info(f"📦 模型已移动到设备: {device}")
    except Exception as e:
        log_error(f"❌ TTS 模型加载失败: {e}")
        log_warning("💡 提示: 尝试使用其他模型或检查网络连接")
        raise

    log_info("✅ TTS 模型加载完成")

    # 生成语音
    log_info(f"🎤 正在生成语音 (语言: {language}, 文本长度: {len(text)} 字符)...")

    import time
    start_time = time.time()

    try:
        # 简化逻辑：统一调用 tts_to_file，让它自己处理参数
        kwargs = {
            'text': text,
            'file_path': output_path
        }
        # 如果是多语言模型，添加语言参数
        is_multilingual = ("xtts" in model_name.lower() or
                           "your_tts" in model_name.lower() or
                           (hasattr(tts, 'is_multi_lingual') and tts.is_multi_lingual))

        if is_multilingual:
            kwargs['language'] = language
            log_info(f"🌐 使用多语言模型，语言: {language}")

        # 如果提供了参考音频，添加 speaker_wav 参数
        if reference_audio:
            kwargs['speaker_wav'] = reference_audio
            log_info(f"🎯 使用参考音频进行语音克隆: {reference_audio}")

        log_info("🔄 开始语音合成...")
        tts.tts_to_file(**kwargs)

        elapsed_time = time.time() - start_time
        log_info(f"⏱️  语音合成耗时: {elapsed_time:.2f} 秒")

    except Exception as e:
        log_error(f"❌ 语音生成失败: {e}")
        raise

    log_info(f"✅ 语音生成完成: {output_path}")
    return output_path


def main():
    parser = argparse.ArgumentParser(
        description="TTS 语音生成工具 - 从文本或文本文件生成指定语言的语音",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 基本使用：直接输入文本
  python video_tts.py --input "Hello world" --language en --output output.wav
  
  # 从文本文件生成语音
  python video_tts.py --input text.txt --language en --output output.wav
  
  # 使用音频样本进行语音克隆（直接文本）
  uv run video_tts.py --input "恭喜恭喜" --language zh --video-sample audio.wav --output output.wav
  
  # 使用指定的 TTS 模型
  python video_tts.py --input "Hello world" --language en --model tts_models/multilingual/multi-dataset/xtts_v2
  
  # 使用 GPU 加速
  python video_tts.py --input "Hello world" --language en --device cuda --output output.wav
        """
    )

    parser.add_argument("--input", "-i", type=str, required=True,
                        help="输入文本或文本文件路径（如果路径存在则读取文件，否则作为文本使用）")
    parser.add_argument("--language", "-l", type=str, required=True, help="目标语言代码 (如: en, zh, fr, de 等)")
    parser.add_argument("--video-sample", "-v", type=str, default=None,
                        help="音频样本路径（可选，用于语音克隆。支持音频文件：.wav, .mp3, .flac, .m4a, .aac, .ogg, .opus 等）")
    parser.add_argument("--model", "-m", type=str, default=None, help="TTS 模型名称，如果未指定则根据语言自动选择")
    parser.add_argument("--output", "-o", type=str, default=None, help="输出音频文件路径（.wav），如果未指定则自动生成")
    parser.add_argument("--device", type=str, default="cpu", choices=["cpu", "cuda"], help="设备类型 (cpu 或 cuda)")
    parser.add_argument("--prefer-multilingual", action="store_true",
                        help="优先使用多语言模型（XTTS v2）。默认优先使用稳定的单语言模型")

    args = parser.parse_args()

    try:
        output_path = generate_speech(
            input_text=args.input,
            language=args.language,
            video_sample=args.video_sample,
            model_name=args.model,
            output_path=args.output,
            device=args.device,
            prefer_multilingual=args.prefer_multilingual
        )

        print(f"\n🎉 处理完成！")
        print(f"📁 输出文件: {output_path}")
        sys.exit(0)

    except KeyboardInterrupt:
        print("\n⚠️  用户中断操作")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ 错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
