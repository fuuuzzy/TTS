"""
Voice Processor - 使用 video_tts API 进行语音生成
"""

import logging
import threading
from pathlib import Path
from typing import Dict, Any, Optional

# 导入 video_tts 的函数和 TTS API
from video_tts import select_model, get_text_from_input
from TTS.api import TTS

logger = logging.getLogger(__name__)


class AudioTooQuietError(Exception):
    """音频太安静的错误"""

    def __init__(self, message: str, rms_level: float = None, threshold: float = None,
                 error_code: str = "AUDIO_TOO_QUIET"):
        super().__init__(message)
        self.rms_level = rms_level
        self.threshold = threshold
        self.error_code = error_code


def _download_audio_from_url(url: str, output_path: str) -> str:
    """
    从 URL 下载音频文件

    Args:
        url: 音频文件 URL
        output_path: 本地保存路径

    Returns:
        str: 下载后的文件路径
    """
    try:
        import requests

        logger.info(f"Downloading audio from URL: {url}")
        response = requests.get(url, timeout=30)
        response.raise_for_status()

        with open(output_path, 'wb') as f:
            f.write(response.content)

        logger.info(f"Audio downloaded to: {output_path}")
        return output_path

    except Exception as e:
        logger.error(f"Failed to download audio from {url}: {str(e)}")
        raise


class VoiceProcessor:
    """语音处理器 - 使用 video_tts API，支持模型缓存"""
    
    # 类级别的模型缓存：{ (model_name, device): TTS实例 }
    _tts_cache: Dict[tuple, TTS] = {}
    _cache_lock = threading.Lock()

    def __init__(self, config: Dict[str, Any]):
        """
        初始化语音处理器

        Args:
            config: 语音克隆配置字典，包含：
                - output_dir: 输出目录
                - temp_dir: 临时目录
                - device: 设备类型 ('cpu' 或 'cuda' 或 None 表示自动)
        """
        self.config = config
        self.output_dir = Path(config.get('output_dir', 'outputs'))
        self.temp_dir = Path(config.get('temp_dir', 'temp'))
        self.device = config.get('device')

        # 如果 device 为 None，自动检测
        if self.device is None:
            try:
                import torch
                self.device = "cuda" if torch.cuda.is_available() else "cpu"
            except ImportError:
                self.device = "cpu"

        # 确保目录存在
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.temp_dir.mkdir(parents=True, exist_ok=True)

        logger.info(f"VoiceProcessor initialized: output_dir={self.output_dir}, device={self.device}")
    
    def _get_or_create_tts(self, model_name: str, logger_instance: Optional[logging.Logger] = None) -> TTS:
        """
        获取或创建 TTS 实例（带缓存）
        
        Args:
            model_name: TTS 模型名称
            logger_instance: 日志记录器（可选）
        
        Returns:
            TTS: TTS 实例
        """
        # 使用传入的 logger 或模块默认 logger
        task_logger = logger_instance if logger_instance is not None else logger
        
        cache_key = (model_name, self.device)
        
        # 检查缓存
        with self._cache_lock:
            if cache_key in self._tts_cache:
                task_logger.info(f"使用缓存的 TTS 模型: {model_name} (device: {self.device})")
                return self._tts_cache[cache_key]
            
            # 创建新的 TTS 实例
            task_logger.info(f"🤖 正在初始化 TTS 模型: {model_name} (device: {self.device})")
            try:
                tts = TTS(model_name=model_name, progress_bar=False)  # 禁用进度条，避免输出混乱
                task_logger.info(f"📥 模型加载中...")
                tts.to(self.device)
                task_logger.info(f"📦 模型已移动到设备: {self.device}")
                
                # 缓存实例
                self._tts_cache[cache_key] = tts
                task_logger.info(f"✅ TTS 模型已缓存: {model_name}")
                
                return tts
            except Exception as e:
                task_logger.error(f"❌ TTS 模型加载失败: {e}")
                raise

    def _get_audio_sample_path(self, spk_audio_prompt: str, task_id: str) -> str:
        """
        获取参考音频文件路径（支持 URL 和本地路径）
        
        Args:
            spk_audio_prompt: 音频 URL 或本地路径
            task_id: 任务 ID
        
        Returns:
            str: 音频文件路径
        """
        # 如果是 URL，下载到临时目录
        if spk_audio_prompt.startswith(('http://', 'https://')):
            filename = f"{task_id}_reference_{Path(spk_audio_prompt).name}"
            local_path = self.temp_dir / filename

            # 如果文件已存在，直接返回
            if local_path.exists():
                return str(local_path)

            return _download_audio_from_url(spk_audio_prompt, str(local_path))

        # 如果是本地路径，检查是否存在
        local_path = Path(spk_audio_prompt)
        if not local_path.exists():
            raise FileNotFoundError(f"Audio file not found: {spk_audio_prompt}")

        return str(local_path)

    def process_single(
            self,
            text: str,
            language: str,
            spk_audio_prompt: str,
            task_id: str,
            model_name: Optional[str] = None,
            logger_instance: Optional[logging.Logger] = None
    ) -> str:
        """
        处理单个语音克隆任务
        
        Args:
            text: 要合成的文本
            language: 语言代码（如 'en', 'zh', 'ja' 等，直接使用，无需映射）
            spk_audio_prompt: 参考音频 URL 或本地路径
            task_id: 任务 ID
            model_name: 模型名称（可选，如果为 None 则自动选择）
            logger_instance: 日志记录器（可选），如果提供则使用，否则使用模块默认 logger
        
        Returns:
            str: 生成的音频文件路径
        
        Raises:
            AudioTooQuietError: 参考音频太安静
            Exception: 其他处理错误
        
        Note:
            如果参考音频是从 URL 下载的，会在处理完成后自动清理临时文件
        """
        # 使用传入的 logger 或模块默认 logger
        task_logger = logger_instance if logger_instance is not None else logger

        temp_file_to_cleanup = None
        try:
            # 获取参考音频路径
            audio_sample_path = self._get_audio_sample_path(spk_audio_prompt, task_id)
            
            # 如果是从 URL 下载的文件（在 temp_dir 中），标记需要清理
            if spk_audio_prompt.startswith(('http://', 'https://')):
                temp_file_to_cleanup = audio_sample_path

            # 生成输出路径
            output_filename = f"{task_id}_output.wav"
            output_path = self.output_dir / output_filename

            task_logger.info(f"[{task_id}] Processing: language={language}, text_length={len(text)}")

            # 确定使用的模型
            if model_name is None:
                model_name = select_model(language)
            
            # 获取或创建 TTS 实例（带缓存）
            tts = self._get_or_create_tts(model_name, logger_instance=task_logger)
            
            # 读取文本内容（如果输入是文件路径）
            try:
                processed_text = get_text_from_input(text)
            except Exception:
                # 如果 get_text_from_input 失败，假设 text 本身就是文本内容
                processed_text = text.strip()
                if not processed_text:
                    raise ValueError("输入的文本不能为空")
            
            # 生成语音
            task_logger.info(f"🎤 正在生成语音 (语言: {language}, 文本长度: {len(processed_text)} 字符)...")
            
            import time
            start_time = time.time()
            
            try:
                # 准备 TTS 参数
                kwargs = {
                    'text': processed_text,
                    'file_path': str(output_path)
                }
                
                # 检查模型是否支持多语言（使用 TTS API 的 is_multi_lingual 属性）
                is_multilingual = False
                try:
                    is_multilingual = tts.is_multi_lingual
                    if is_multilingual:
                        supported_langs = tts.languages if tts.languages else []
                        task_logger.info(f"🌐 检测到多语言模型，支持的语言: {supported_langs}")
                except (AttributeError, Exception) as e:
                    # 如果无法获取属性，回退到字符串匹配
                    task_logger.debug(f"无法获取模型多语言属性，使用回退判断: {e}")
                    is_multilingual = ("xtts" in model_name.lower() or 
                                     "your_tts" in model_name.lower())
                
                # 如果是多语言模型，添加语言参数
                if is_multilingual:
                    # 标准化语言代码
                    # XTTS v2 使用的语言代码映射：
                    # - zh/zh-cn/chinese/cn -> zh-cn
                    # - 其他保持原样（如 en, fr, de, es, it, pt, pl, tr, ru, nl, cs, ar, ja, hu, ko）
                    normalized_language = language.lower()
                    if normalized_language in ['zh', 'chinese', 'cn']:
                        normalized_language = 'zh-cn'
                    elif normalized_language == 'zh-cn':
                        normalized_language = 'zh-cn'  # 保持
                    
                    kwargs['language'] = normalized_language
                    task_logger.info(f"🌐 使用多语言模型，语言代码: {normalized_language}")
                else:
                    # 单语言模型不需要语言参数，但如果传入了会被 TTS API 的 _check_arguments 忽略
                    task_logger.debug(f"使用单语言模型: {model_name}，不传递语言参数")
                
                # 如果提供了参考音频，添加 speaker_wav 参数
                if audio_sample_path:
                    kwargs['speaker_wav'] = audio_sample_path
                    task_logger.info(f"🎯 使用参考音频进行语音克隆: {audio_sample_path}")
                
                task_logger.info(f"🔄 开始语音合成...")
                tts.tts_to_file(**kwargs)
                
                elapsed_time = time.time() - start_time
                task_logger.info(f"⏱️  语音合成耗时: {elapsed_time:.2f} 秒")
                
            except Exception as e:
                task_logger.error(f"❌ 语音生成失败: {e}")
                raise
            
            task_logger.info(f"[{task_id}] Voice generation completed: {output_path}")
            return str(output_path)

        except Exception as e:
            task_logger.error(f"[{task_id}] Voice generation failed: {str(e)}", exc_info=True)
            raise
        finally:
            # 清理临时文件（无论成功还是失败）
            if temp_file_to_cleanup and Path(temp_file_to_cleanup).exists():
                try:
                    Path(temp_file_to_cleanup).unlink()
                    task_logger.info(f"[{task_id}] Cleaned up temporary file: {temp_file_to_cleanup}")
                except Exception as cleanup_error:
                    task_logger.warning(
                        f"[{task_id}] Failed to cleanup temp file {temp_file_to_cleanup}: {str(cleanup_error)}")
