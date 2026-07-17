import SwiftUI

struct GroupingPickerView: View {
    @Binding var mode: GroupingMode

    var body: some View {
        Picker("Group By", selection: $mode) {
            ForEach(GroupingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
    }
}
