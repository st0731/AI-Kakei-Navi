import SwiftUI
import PhotosUI
import SwiftData
import Vision

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0
    @State private var isShowingSplash = true

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()

            TabView(selection: $selectedTab) {
                ReceiptAnalysisView()
                    .tabItem { Label("登録", systemImage: "camera.viewfinder") }
                    .tag(0)

                ReceiptHistoryView()
                    .tabItem { Label("履歴", systemImage: "list.bullet") }
                    .tag(1)

                InsightAnalyticsView()
                    .tabItem { Label("分析", systemImage: "chart.pie.fill") }
                    .tag(2)

                AdviceView()
                    .tabItem { Label("節約AI", systemImage: "message") }
                    .tag(3)

                SettingsView()
                    .tabItem { Label("設定", systemImage: "gearshape.fill") }
                    .tag(4)
            }
            .opacity(isShowingSplash ? 0 : 1)

            if isShowingSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            AIServiceManager.shared.prewarmServices()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    isShowingSplash = false
                }
            }
        }
    }
}
