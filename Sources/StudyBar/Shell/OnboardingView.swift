import SwiftUI

/// First-run 3-step setup. Adds first courses so the app isn't a blank slate.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    let done: () -> Void
    @State private var step = 0
    @State private var courseName = ""
    @State private var colorHex = Palette.swatches[0]

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                switch step {
                case 0: welcome
                case 1: addCourses
                default: finish
                }
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
            .shadow(radius: 24)
            .padding(24)
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "graduationcap.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Welcome to StudyBar").font(.title2.bold())
            Text("Your whole study life, one click away in the menu bar. Everything stays on your Mac — no account, no cloud, no paywall.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Get started") { step = 1 }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Skip setup") { done() }.buttonStyle(.borderless).font(.caption)
        }
    }

    private var addCourses: some View {
        VStack(spacing: 12) {
            Text("Add your courses").font(.title3.bold())
            Text("Assignments, notes, timers and links all attach to a course.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Circle().fill(Color(hex: colorHex) ?? .blue).frame(width: 16, height: 16)
                TextField("Course name (e.g. Biology 101)", text: $courseName, onCommit: addCourse)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: addCourse).disabled(courseName.isEmpty)
            }
            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 7), spacing: 6) {
                ForEach(Palette.swatches.prefix(7), id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle().fill(Color(hex: hex) ?? .gray).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(.primary, lineWidth: colorHex == hex ? 2 : 0))
                    }.buttonStyle(.plain)
                }
            }
            if !addedCourses.isEmpty {
                VStack(spacing: 4) {
                    ForEach(addedCourses) { c in
                        HStack {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            Text(c.name); Spacer()
                        }.font(.caption)
                    }
                }.padding(8).frame(maxWidth: .infinity)
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: 8))
            }
            Button("Continue") { step = 2 }.buttonStyle(.borderedProminent)
        }
    }

    private var finish: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("You're set").font(.title2.bold())
            Text("Tip: press ⌘K anywhere for the command palette. New — turn on the **Assistant** (Settings ▸ Intelligence) to organize assignments, plan sessions and make flashcards from your own notes. It never does your homework.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Start studying") { state.selectedModuleID = "today"; done() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var addedCourses: [Course] {
        state.data.courses.filter { $0.name != "Getting Started" }
    }
    private func addCourse() {
        let n = courseName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        state.data.courses.append(Course(name: n, colorHex: colorHex))
        courseName = ""
        if let next = Palette.swatches.first(where: { !state.data.courses.map(\.colorHex).contains($0) }) {
            colorHex = next
        }
    }
}
