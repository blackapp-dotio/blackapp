// WallInterestSelector.swift
// Lets users pick content categories for their profile wall

import SwiftUI

struct WallInterestSelector: View {
    @Binding var selectedCategories: Set<FeedCategory>
    var onDone: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Choose Your Interests")) {
                    ForEach(FeedCategory.allCases) { category in
                        Toggle(isOn: Binding(
                            get: { selectedCategories.contains(category) },
                            set: { isOn in
                                if isOn {
                                    selectedCategories.insert(category)
                                } else {
                                    selectedCategories.remove(category)
                                }
                            }
                        )) {
                            Text(category.rawValue)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Customize Your Wall")
            .navigationBarItems(trailing: Button("Done") {
                onDone()
            })
        }
    }
}
