import Testing
@testable import CHLocalLLM

@Suite("LiftCoach app identity")
struct LiftCoachIdentityTests {
    @Test func currentIdentityUsesLiftCoachBranding() {
        let app = AppIdentifier.liftcoach
        #expect(app.rawValue == "liftcoach")
        #expect(app.displayName == "LiftCoach")
        #expect(app.onboardingBlurb.contains("LiftCoach"))
        #expect(app.defaultDownloadCompletionBody.contains("LiftCoach"))
        #expect(app.downloadCompletionNotificationIdentifier == "app.chen.liftcoach.llm.ready")
    }

    @Test func legacyRawValueRemainsReadableWithCurrentBranding() throws {
        let legacy = try #require(AppIdentifier(rawValue: "gymlog"))
        #expect(legacy.rawValue == "gymlog")
        #expect(legacy.displayName == "LiftCoach")
        #expect(legacy.onboardingBlurb == AppIdentifier.liftcoach.onboardingBlurb)
        #expect(legacy.defaultDownloadCompletionBody == AppIdentifier.liftcoach.defaultDownloadCompletionBody)
        #expect(legacy.downloadCompletionNotificationIdentifier == "app.chen.gymlog.llm.ready")
    }

    @Test func modelRecommendationsPreserveTrainingFit() throws {
        let legacy = try #require(AppIdentifier(rawValue: "gymlog"))
        for model in LocalModelCatalog.all {
            #expect(model.recommendationScore(for: .liftcoach) == model.recommendationScore(for: legacy))
            #expect(model.taskHint(for: .liftcoach) == model.taskHint(for: legacy))
        }
        #expect(LocalModelCatalog.qwen2_5_3B.recommendationScore(for: .liftcoach) == 10)
    }
}
