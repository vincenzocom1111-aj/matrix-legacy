class CourseGenerationJob {
  CourseGenerationJob({
    required this.jobId,
    required this.status,
    this.stage = '',
    this.stageMessage = '',
    this.partialText = '',
    this.tokensGenerated = 0,
    this.efficiencyScore,
    this.evaluationFeedback,
    this.iteration = 1,
    this.resultText,
    this.errorMessage,
  });

  factory CourseGenerationJob.fromJson(Map<String, dynamic> json) =>
      CourseGenerationJob(
        jobId: json['job_id']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
        stage: json['stage']?.toString() ?? '',
        stageMessage: json['stage_message']?.toString() ?? '',
        partialText: json['partial_text']?.toString() ?? '',
        tokensGenerated: (json['tokens_generated'] as num?)?.toInt() ?? 0,
        efficiencyScore: (json['efficiency_score'] as num?)?.toInt(),
        evaluationFeedback: json['evaluation_feedback']?.toString(),
        iteration: (json['iteration'] as num?)?.toInt() ?? 1,
        resultText: json['result_text']?.toString(),
        errorMessage: json['error_message']?.toString(),
      );

  final String jobId;
  final String status; // pending | processing | done | failed
  final String stage; // extracting | analyzing | generating | evaluating | refining | done | failed
  final String stageMessage; // Real-time descriptive status message
  final String partialText; // live streaming preview
  final int tokensGenerated;
  final int? efficiencyScore; // 0-100 percentage
  final String? evaluationFeedback;
  final int iteration;
  final String? resultText;
  final String? errorMessage;

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending' || status == 'processing';
  bool get isVerified => (efficiencyScore ?? 0) >= 90;
}