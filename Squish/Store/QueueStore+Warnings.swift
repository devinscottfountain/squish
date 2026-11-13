import Foundation

extension QueueStore {
    /// The plan's warnings for a file, for views that redraw often. Same as `plan(for:).warnings`,
    /// but skips `outputURL(for:)` and its disk checks: no warning depends on the output path.
    func warnings(for job: EncodeJob) -> [String] {
        CommandBuilder(settings: effectiveSettings(for: job), input: job.input, output: job.input,
                       media: job.media, encoders: environment.encoders, filters: environment.filters).plan().warnings
    }
}
