import DesignSystem
import SwiftUI

struct PlaybackProgressControl: View {
  @ObservedObject private var viewModel: PlayerViewModel

  init(viewModel: PlayerViewModel) {
    self.viewModel = viewModel
  }

  var body: some View {
    VStack(spacing: MusicFreeSpacingTokens.xSmall) {
      Slider(
        value: Binding(
          get: { PlayerFormatting.seconds(viewModel.displayedPosition) },
          set: { viewModel.updateSeeking(to: .seconds($0)) }
        ),
        in: 0...sliderMaximum,
        onEditingChanged: { isEditing in
          if isEditing {
            viewModel.beginSeeking()
          } else {
            viewModel.finishSeeking()
          }
        }
      )
      .disabled(!viewModel.canSeek)
      .accessibilityLabel(Text("播放进度"))
      .accessibilityValue(
        Text("\(PlayerFormatting.duration(viewModel.displayedPosition)) / \(PlayerFormatting.duration(viewModel.duration))")
      )
      .accessibilityHint(
        Text(viewModel.canSeek ? "拖动调整播放位置" : "当前播放不支持调整位置")
      )

      HStack {
        Text(PlayerFormatting.duration(viewModel.displayedPosition))
        Spacer(minLength: MusicFreeSpacingTokens.small)
        Text(PlayerFormatting.duration(viewModel.duration))
      }
      .font(MusicFreeTypographyTokens.caption.monospacedDigit())
      .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
      .accessibilityHidden(true)
    }
  }

  private var sliderMaximum: Double {
    max(PlayerFormatting.seconds(viewModel.duration ?? .zero), 1)
  }
}
