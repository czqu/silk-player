import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:silk_decoder/silk_decoder.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Silk Player & Converter',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioPlayer _audioPlayer = AudioPlayer();

  String? _ffmpegPath;
  String _status = '请拖拽或选择音频文件';
  String? _currentFilePath;
  String? _currentWavPath;

  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  final Queue<String> _fileQueue = Queue<String>();
  final List<String> _processingLog = [];
  bool _isProcessingQueue = false;
  int _totalQueueCount = 0;
  bool _isCompleted = false;
  final Map<String, String> _successfulFilesMap = {};
  bool _isUserSeeking = false;

  bool _wasPlayingBeforeSeek = false;

  double _sliderValue = 0.0;

  @override
  void initState() {
    super.initState();
    _loadFFmpegPath();

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        if (mounted) {
          setState(() {
            _position = _duration;
            _isCompleted = true;
          });
        }
      } else {
        if (_isCompleted && mounted) {
          setState(() {
            _isCompleted = false;
          });
        }
      }
      if (mounted) setState(() => _playerState = state);
    });

    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) {
        setState(() {
          _duration = d;

          _sliderValue = _position.inMilliseconds.toDouble().clamp(
            0.0,
            d.inMilliseconds.toDouble() == 0.0
                ? 1.0
                : d.inMilliseconds.toDouble(),
          );
        });
      }
    });
    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) {
        if (!_isUserSeeking) {
          setState(() {
            _position = p;
            _sliderValue = p.inMilliseconds.toDouble();
          });
        } else {
          setState(() {
            _position = p;
          });
        }
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _position = _duration;
          _isCompleted = true;
          _playerState = PlayerState.stopped;
        });
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<bool> _validateFFmpegPath(String path) async {
    if (path.isEmpty) return false;
    try {
      final result = await Process.run(path, ['-version']);

      final stdout = result.stdout.toString();
      if (result.exitCode != 0 || !stdout.contains('ffmpeg version')) {
        return false;
      }
      final configuration = stdout
          .split('\n')
          .firstWhere(
            (line) => line.startsWith('configuration:'),
            orElse: () => '',
          );
      final hasSupport = configuration.contains('--enable-libmp3lame');
      if (hasSupport) {
        return true;
      } else {
        return false;
      }
    } catch (e) {
      debugPrint('FFmpeg validation failed: $e');
      return false;
    }
  }

  Future<void> _loadFFmpegPath() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('ffmpeg_path');

    if (savedPath != null && await _validateFFmpegPath(savedPath)) {
      if (mounted) {
        setState(() {
          _ffmpegPath = savedPath;
        });
      }
    } else {
      if (savedPath != null) {
        await prefs.remove('ffmpeg_path');
      }

      await _autoDetectFFmpeg();
    }
  }

  Future<void> _saveFFmpegPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ffmpeg_path', path);
    if (mounted) {
      setState(() {
        _ffmpegPath = path;
      });
    }
  }

  Future<void> _autoDetectFFmpeg() async {
    String command = Platform.isWindows ? 'where' : 'which';
    try {
      ProcessResult result = await Process.run(command, ['ffmpeg']);
      if (result.exitCode == 0) {
        String detectedPath = result.stdout.toString().trim().split('\n').first;

        if (await _validateFFmpegPath(detectedPath)) {
          await _saveFFmpegPath(detectedPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('自动检测到有效的 FFmpeg: $detectedPath')),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('自动检测失败: 未在系统路径中找到 FFmpeg')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('自动检测出错: $e')));
      }
    }
  }

  Future<void> _pickFFmpegPath() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      final pickedPath = result.files.single.path!;
      if (await _validateFFmpegPath(pickedPath)) {
        await _saveFFmpegPath(pickedPath);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('设置成功: $pickedPath')));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('选择的文件无效! 请确保选择的是正确的 FFmpeg 可执行文件。'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _addFilesToQueue(List<String> paths) {
    final validFiles = paths
        .where(
          (path) => [
            '.slk',
            '.aud',
            '.amr',
          ].any((ext) => path.toLowerCase().endsWith(ext)),
        )
        .toList();
    if (validFiles.isEmpty) return;

    _fileQueue.addAll(validFiles);
    _totalQueueCount = _fileQueue.length;

    if (!_isProcessingQueue) {
      _processingLog.clear();
      _successfulFilesMap.clear();
      _processNextFileInQueue();
    }
  }

  Future<void> _processNextFileInQueue() async {
    if (_fileQueue.isEmpty) {
      setState(() {
        _isProcessingQueue = false;
        _status = '所有任务已完成! ${_successfulFilesMap.length} 个文件成功.';
      });
      return;
    }

    _isProcessingQueue = true;
    final filePath = _fileQueue.removeFirst();
    final currentIndex = _totalQueueCount - _fileQueue.length;

    await _processFile(
      filePath,
      isBatch: true,
      batchIndex: currentIndex,
      batchTotal: _totalQueueCount,
    );

    _processNextFileInQueue();
  }

  Future<void> _processFile(
    String filePath, {
    bool isBatch = false,
    int batchIndex = 1,
    int batchTotal = 1,
  }) async {
    if (_ffmpegPath == null || _ffmpegPath!.isEmpty) {
      setState(() {
        _status = '错误: 请先设置 FFmpeg 路径!';
        if (isBatch) {
          _processingLog.add('❌ [跳过] ${p.basename(filePath)} - 未配置 FFmpeg');
        }
      });
      return;
    }

    setState(() {
      if (isBatch) {
        _status = '正在处理 $batchIndex/$batchTotal: ${p.basename(filePath)}';
      } else {
        _processingLog.clear();
        _successfulFilesMap.clear();
        _status = '正在解码...';
      }

      if (!isBatch || batchIndex == 1) {
        _currentFilePath = filePath;
        _playerState = PlayerState.stopped;
        _duration = Duration.zero;
        _position = Duration.zero;
      }
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final pcmPath = p.join(tempDir.path, '${p.basename(filePath)}.pcm');
      final wavPath = p.join(tempDir.path, '${p.basename(filePath)}.wav');

      await decodeSilkFileAsync(filePath, pcmPath, 24000);
      await _convertPcmToWav(pcmPath, wavPath);

      _successfulFilesMap[wavPath] = p.basename(filePath);

      if (!isBatch || batchIndex == 1) {
        await _audioPlayer.setSourceDeviceFile(wavPath);
        await _audioPlayer.resume();
        setState(() {
          _status = '准备就绪: ${p.basename(filePath)}';
          _currentWavPath = wavPath;
        });
      }

      _processingLog.add('✅ [成功] ${p.basename(filePath)}');
      setState(() {});
    } catch (e) {
      final errorMsg = '处理失败: ${p.basename(filePath)}';
      _processingLog.add(
        '❌ [失败] ${p.basename(filePath)} - ${e.toString().split('\n').first}',
      );
      setState(() {
        _status = errorMsg;
      });
    }
  }

  Future<void> _convertPcmToWav(String pcmPath, String wavPath) async {
    final result = await Process.run(_ffmpegPath!, [
      '-y',
      '-f',
      's16le',
      '-ar',
      '24000',
      '-ac',
      '1',
      '-i',
      pcmPath,
      '-c:a',
      'pcm_s16le',
      wavPath,
    ]);
    if (result.exitCode != 0) {
      throw Exception('FFmpeg 转换失败: ${result.stderr}');
    }
  }

  Future<void> _runFFmpegConversion(String inputPath, String outputPath) async {
    final result = await Process.run(_ffmpegPath!, [
      '-y',
      '-i',
      inputPath,
      outputPath,
    ]);

    if (result.exitCode != 0) {
      throw Exception('FFmpeg 导出失败: ${result.stderr}');
    }
  }

  Future<void> _exportSingleFile(String format) async {
    if (_currentWavPath == null) return;

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: '请选择保存位置:',
      fileName: '${p.basenameWithoutExtension(_currentFilePath!)}.$format',
    );
    if (outputFile == null) return;

    setState(() => _status = '正在导出为 $format...');

    try {
      await _runFFmpegConversion(_currentWavPath!, outputFile);
      setState(() {
        _status = '导出成功: $outputFile';
        _processingLog.add('🚀 [导出] $outputFile');
      });
    } catch (e) {
      setState(() {
        _status = '导出失败: $e';
        _processingLog.add('❌ [导出失败] $e');
      });
    }
  }

  Future<void> _batchExportFiles(String format) async {
    String? outputDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '请选择导出文件夹',
    );
    if (outputDir == null) return;

    int successCount = 0;
    _processingLog.add('--- 开始批量导出为 $format ---');
    setState(() => _isProcessingQueue = true);

    for (final entry in _successfulFilesMap.entries) {
      final wavPath = entry.key;
      final originalFilename = entry.value;
      final outputFilename =
          '${p.basenameWithoutExtension(originalFilename)}.$format';
      final outputPath = p.join(outputDir, outputFilename);

      setState(() {
        _status =
            '正在导出 ${successCount + 1}/${_successfulFilesMap.length}: $outputFilename';
      });

      try {
        await _runFFmpegConversion(wavPath, outputPath);
        _processingLog.add('✅ [导出] $outputFilename');
        successCount++;
      } catch (e) {
        _processingLog.add(
          '❌ [导出失败] $outputFilename - ${e.toString().split('\n').first}',
        );
      }
      setState(() {});
    }

    _processingLog.add('--- 批量导出完成. $successCount 个文件成功. ---');
    setState(() {
      _status = '批量导出完成!';
      _isProcessingQueue = false;
    });
  }

  Future<void> _showBatchExportDialog() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择批量导出格式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('导出为 MP3'),
              onTap: () {
                Navigator.of(context).pop();
                _batchExportFiles('mp3');
              },
            ),
            ListTile(
              title: const Text('导出为 WAV'),
              onTap: () {
                Navigator.of(context).pop();
                _batchExportFiles('wav');
              },
            ),
            ListTile(
              title: const Text('导出为 M4A (AAC)'),
              onTap: () {
                Navigator.of(context).pop();
                _batchExportFiles('m4a');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Silk 播放和转换工具')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildFFmpegStatusCard(),
              const SizedBox(height: 20),
              if (_currentFilePath != null) _buildPlayerControls(),
              const SizedBox(height: 20),
              _buildDropZone(),
              const SizedBox(height: 20),
              SizedBox(height: 200, child: _buildInfoZone()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropZone() {
    return DropTarget(
      onDragDone: (details) {
        final paths = details.files.map((file) => file.path).toList();
        _addFilesToQueue(paths);
      },
      child: InkWell(
        onTap: () async {
          FilePickerResult? result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['slk', 'aud', 'amr'],
            allowMultiple: true,
          );
          if (result != null) {
            _addFilesToQueue(
              result.paths.where((p) => p != null).cast<String>().toList(),
            );
          }
        },
        child: Container(
          height: 150,
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.grey.shade600,
              style: BorderStyle.solid,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.upload_file, size: 50),
                SizedBox(height: 10),
                Text('拖拽文件到这里或点击选择 (支持多选)'),
                Text('.slk, .aud, .amr', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFFmpegStatusCard() {
    bool isConfigured = _ffmpegPath != null && _ffmpegPath!.isNotEmpty;
    return Card(
      color:
          isConfigured
                ? Colors.green.withAlpha((255 * 0.3).round())
                : Colors.red
            ..withAlpha((255 * 0.3).round()),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isConfigured ? Icons.check_circle : Icons.error,
                  color: isConfigured ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  'FFmpeg 配置',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              isConfigured ? _ffmpegPath! : '未找到 FFmpeg. 请自动检测或手动选择路径.',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _autoDetectFFmpeg,
                  child: const Text('自动检测'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _pickFFmpegPath,
                  child: const Text('手动选择'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _safeSeek(Duration position, {bool resumeAfter = false}) async {
    if (_currentWavPath == null) return;

    try {
      if (_isCompleted || _playerState == PlayerState.completed) {
        try {
          await _audioPlayer.stop().timeout(const Duration(seconds: 5));
        } catch (_) {}

        try {
          await _audioPlayer
              .setSourceDeviceFile(_currentWavPath!)
              .timeout(const Duration(seconds: 5));
        } catch (_) {}

        _isCompleted = false;
      }

      await _audioPlayer.seek(position).timeout(const Duration(seconds: 5));

      if (resumeAfter) {
        try {
          await _audioPlayer.resume().timeout(const Duration(seconds: 5));
        } catch (_) {
          try {
            await _audioPlayer.setSourceDeviceFile(_currentWavPath!);
            await _audioPlayer.seek(position);
            await _audioPlayer.resume();
          } catch (e) {
            debugPrint('resume fallback failed: $e');
          }
        }
      }
    } on TimeoutException catch (te) {
      debugPrint('safeSeek timeout: $te');

      try {
        await _audioPlayer.stop();
        await _audioPlayer.setSourceDeviceFile(_currentWavPath!);
        await _audioPlayer.seek(position);
      } catch (e2) {
        debugPrint('safeSeek fallback failed: $e2');
      }
    } catch (e) {
      debugPrint('safeSeek error: $e');
    } finally {
      if (mounted) setState(() {});
    }
  }

  Widget _buildPlayerControls() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.music_note, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.basename(_currentFilePath ?? ''),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Slider(
              value: (_duration.inMilliseconds > 0)
                  ? _sliderValue.clamp(0.0, _duration.inMilliseconds.toDouble())
                  : 0.0,
              max: (_duration.inMilliseconds > 0)
                  ? _duration.inMilliseconds.toDouble()
                  : 1.0,
              onChangeStart: (value) {
                _isUserSeeking = true;
                _wasPlayingBeforeSeek = _playerState == PlayerState.playing;
              },
              onChanged: (value) {
                setState(() {
                  _sliderValue = value;
                });
              },
              onChangeEnd: (value) async {
                _isUserSeeking = false;
                final newPosition = Duration(milliseconds: value.round());
                await _safeSeek(
                  newPosition,
                  resumeAfter: _wasPlayingBeforeSeek,
                );

                if (mounted) {
                  setState(() {
                    _position = newPosition;
                    _sliderValue = newPosition.inMilliseconds.toDouble();
                    if (_isCompleted && newPosition < _duration) {
                      _isCompleted = false;
                    }
                  });
                }
              },
            ),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(_position)),
                Text(_formatDuration(_duration)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(
                    _playerState == PlayerState.playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                  ),
                  iconSize: 48,
                  onPressed: _currentWavPath == null
                      ? null
                      : () async {
                          if (_playerState == PlayerState.playing) {
                            await _audioPlayer.pause();
                            if (mounted) {
                              setState(() => _playerState = PlayerState.paused);
                              return;
                            }
                          }

                          if (_isCompleted ||
                              _playerState == PlayerState.completed) {
                            final safePosition = _position >= _duration
                                ? Duration.zero
                                : _position;
                            await _safeSeek(safePosition, resumeAfter: true);
                          } else {
                            try {
                              await _audioPlayer.resume();
                            } catch (e) {
                              try {
                                await _audioPlayer.setSourceDeviceFile(
                                  _currentWavPath!,
                                );
                                await _audioPlayer.seek(_position);
                                await _audioPlayer.resume();
                              } catch (e2) {
                                debugPrint('play fallback failed: $e2');
                              }
                            }
                          }
                        },
                ),
                const SizedBox(width: 20),
                PopupMenuButton<String>(
                  onSelected: _exportSingleFile,
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(
                          value: 'wav',
                          child: Text('导出为 WAV'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'mp3',
                          child: Text('导出为 MP3'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'm4a',
                          child: Text('导出为 M4A (AAC)'),
                        ),
                      ],
                  child: const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        Icon(Icons.save_alt),
                        SizedBox(width: 8),
                        Text('导出当前'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildInfoZone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                _status,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),

            if (_successfulFilesMap.isNotEmpty && !_isProcessingQueue)
              ElevatedButton.icon(
                onPressed: _showBatchExportDialog,
                icon: const Icon(Icons.collections_bookmark),
                label: Text('批量导出 (${_successfulFilesMap.length})'),
              ),
          ],
        ),
        const Divider(height: 32),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12.0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest
                  .withAlpha((255 * 0.3).round()),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _processingLog.isEmpty
                ? const Center(
                    child: Text(
                      '日志将显示在这里',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _processingLog.length,
                    itemBuilder: (context, index) {
                      return SelectableText(
                        _processingLog[index],
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
