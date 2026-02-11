# Better Code: Human Interface

> "The goal is: Don't Lie."

## Overview

Sean Parent's "Better Code: Human Interface" talk explores the deep connection between code quality and user interface design. The central thesis is that the semantics of a user interface are tightly coupled with code semantics—improving how we reason about code directly improves the human interface behavior of the system.

When code lies (violates its contracts, behaves inconsistently), the UI lies to the user, creating confusion and frustration.

## The UI Is the Program

From the user's perspective, **the interface IS the program**. They don't see the code—they experience the interface.

```
Code Quality → UI Quality

Bad code    → Confusing UI
             → Inconsistent behavior
             → Unexpected states
             → Misleading feedback

Good code   → Intuitive UI
             → Predictable behavior
             → Clear states
             → Accurate feedback
```

## Don't Lie to the User

### What "Lying" Means

The UI lies when it misrepresents the system state:

| Lie                                           | Truth                                   |
| --------------------------------------------- | --------------------------------------- |
| Button appears enabled but does nothing       | Button should be disabled               |
| Progress bar shows 50% but operation is stuck | Show indeterminate or accurate progress |
| "Save" completes but data isn't saved         | Show error or actually save             |
| Available option that can't be selected       | Don't show unavailable options          |

### Common UI Lies

**1. Fake Enablement**

```cpp
// BAD: Button enabled but action can fail
void onSaveClick() {
    if (!canSave()) {
        showError("Cannot save");  // User clicked enabled button!
        return;
    }
    save();
}

// GOOD: Button reflects actual capability
void updateUI() {
    saveButton.setEnabled(canSave());
}
```

**2. Misleading Progress**

```cpp
// BAD: Progress doesn't reflect reality
void downloadFile() {
    for (int i = 0; i <= 100; ++i) {
        progressBar.setValue(i);  // Fake progress
        sleep(100);
    }
    actualDownload();  // Real work here
}

// GOOD: Progress reflects actual state
void downloadFile() {
    connection.onProgress([&](float progress) {
        progressBar.setValue(progress * 100);
    });
    connection.download();
}
```

**3. Inconsistent State Display**

```cpp
// BAD: UI can show impossible state
void updateUI() {
    // Can show "Connected" with disabled "Send" button
    statusLabel.setText(isConnected() ? "Connected" : "Disconnected");
    sendButton.setEnabled(canSend());  // Different condition!
}

// GOOD: Consistent state model
void updateUI() {
    auto state = getConnectionState();
    statusLabel.setText(state.displayText());
    sendButton.setEnabled(state.canSend());
}
```

## The Property Model

Sean Parent developed the "Property Model" approach at Adobe for managing UI state:

### What Is a Property Model?

A property model is a declarative specification of:

- The values in a UI
- The relationships between values
- The validation rules
- The computation dependencies

```cpp
// Property model for a dialog
struct ResizeDialogModel {
    // Values
    int width = 100;
    int height = 100;
    bool maintainAspect = true;
    float aspectRatio = 1.0f;

    // Constraints
    void onWidthChanged(int newWidth) {
        width = std::clamp(newWidth, 1, 10000);
        if (maintainAspect) {
            height = static_cast<int>(width / aspectRatio);
        }
    }

    void onHeightChanged(int newHeight) {
        height = std::clamp(newHeight, 1, 10000);
        if (maintainAspect) {
            width = static_cast<int>(height * aspectRatio);
        }
    }

    void onAspectToggled(bool maintain) {
        maintainAspect = maintain;
        if (maintain) {
            aspectRatio = static_cast<float>(width) / height;
        }
    }
};
```

### Benefits of Property Models

1. **Declarative**: Specify what, not how
2. **Consistent**: Model enforces validity
3. **Testable**: Logic separate from UI
4. **Reusable**: Same model, different UIs

## Command and State

### Commands Should Be Honest

```cpp
// A command that can't fail should always work
// A command that might fail should indicate it

class Command {
public:
    // Query: Can this command execute?
    virtual bool canExecute() const = 0;

    // Action: Execute the command
    // @pre canExecute()
    virtual void execute() = 0;

    // Notification: When can-execute state changes
    Signal<void()> canExecuteChanged;
};

// UI binds to this
void bindCommand(Button& button, Command& cmd) {
    button.setEnabled(cmd.canExecute());
    cmd.canExecuteChanged.connect([&] {
        button.setEnabled(cmd.canExecute());
    });
    button.onClick([&] {
        if (cmd.canExecute()) {
            cmd.execute();
        }
    });
}
```

### State Machines for Complex UI

```cpp
enum class ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
    Error
};

class ConnectionStateMachine {
    ConnectionState state_ = ConnectionState::Disconnected;

public:
    // Valid transitions only
    void connect() {
        assert(state_ == ConnectionState::Disconnected);
        state_ = ConnectionState::Connecting;
        // Start async connection
    }

    void onConnected() {
        assert(state_ == ConnectionState::Connecting);
        state_ = ConnectionState::Connected;
    }

    void disconnect() {
        assert(state_ == ConnectionState::Connected);
        state_ = ConnectionState::Disconnecting;
        // Start async disconnect
    }

    // UI queries
    bool canConnect() const { return state_ == ConnectionState::Disconnected; }
    bool canDisconnect() const { return state_ == ConnectionState::Connected; }
    bool isBusy() const {
        return state_ == ConnectionState::Connecting ||
               state_ == ConnectionState::Disconnecting;
    }
};
```

## Undo/Redo

### The Problem

Undo is hard because:

- Must track all changes
- Must reverse operations correctly
- State can be complex

### The Solution: Value Semantics

With value semantics, undo is trivial:

```cpp
class DocumentEditor {
    Document current_;
    std::vector<Document> undoStack_;
    std::vector<Document> redoStack_;

public:
    void modify(auto&& operation) {
        undoStack_.push_back(current_);
        redoStack_.clear();
        operation(current_);
    }

    void undo() {
        if (!undoStack_.empty()) {
            redoStack_.push_back(std::move(current_));
            current_ = std::move(undoStack_.back());
            undoStack_.pop_back();
        }
    }

    void redo() {
        if (!redoStack_.empty()) {
            undoStack_.push_back(std::move(current_));
            current_ = std::move(redoStack_.back());
            redoStack_.pop_back();
        }
    }
};
```

## Guidelines

### 1. UI State Should Mirror Model State

```cpp
// BAD: UI has its own idea of state
class Dialog {
    bool isValid_ = true;  // UI's opinion
    void validate() {
        isValid_ = /* check fields */;
    }
};

// GOOD: UI reflects model state
class Dialog {
    Model& model_;
    void updateUI() {
        okButton.setEnabled(model_.isValid());
        errorLabel.setText(model_.validationError());
    }
};
```

### 2. Make Invalid States Impossible

```cpp
// BAD: Can create invalid combination
struct Options {
    bool compress = false;
    bool encrypt = false;
    int compressionLevel = 0;  // Only valid if compress is true
};

// GOOD: Type system prevents invalid states
struct Options {
    struct NoCompression {};
    struct Compression { int level; };
    std::variant<NoCompression, Compression> compression;
    bool encrypt = false;
};
```

### 3. Feedback Should Be Immediate

```cpp
// BAD: Validation on submit
void onSubmit() {
    if (!validate()) {
        showErrors();  // User finds out too late
        return;
    }
    submit();
}

// GOOD: Live validation
void onFieldChanged() {
    auto errors = validate();
    updateErrorDisplay(errors);
    submitButton.setEnabled(errors.empty());
}
```

### 4. Progress Should Be Accurate

```cpp
// BAD: Fake or stuck progress
progressBar.setValue(50);  // Always 50%

// GOOD: Actual progress or indeterminate
if (operation.knowsProgress()) {
    progressBar.setMode(Determinate);
    progressBar.setValue(operation.progress());
} else {
    progressBar.setMode(Indeterminate);
}
```

### 5. Commands Should Be Discoverable

```cpp
// BAD: Hidden functionality
// User must guess Ctrl+Shift+Alt+F7 does something

// GOOD: Visible and consistent
// Menu shows command with keyboard shortcut
// Toolbar button with tooltip
// Context menu in relevant places
```

## The Photoshop Example

Sean Parent often uses Photoshop as an example of complex UI with:

- Multiple undo/redo
- Non-destructive editing
- Real-time preview
- Consistent command model

The key insight: **Good architecture enables good UI**.

```
Good Model          → Good UI
- Value semantics   → Easy undo
- Clear states      → Accurate display
- Explicit dependencies → Live updates
- Command pattern   → Consistent actions
```

## References

### Primary Sources

- **[Better Code: Human Interface (YouTube)](https://www.youtube.com/watch?v=0WlJEz2wb8Y)** — CppCon 2018
- **[Slides (PDF)](https://sean-parent.stlab.cc/presentations/2018-09-28-human-interface/2018-09-28-human-interface.pdf)**

### Related Papers

- **[Property Models: From Incidental Algorithms to Reusable Components](https://sean-parent.stlab.cc/papers/2008-10-gpce/p89-jarvi.pdf)** — GPCE 2008
- **[Algorithms for User Interfaces](https://sean-parent.stlab.cc/papers/2009-10-04-gpce/p147-jarvi.pdf)** — GPCE 2009

### Related Talks

- **Value Semantics and Concept-based Polymorphism** — Enables easy undo
- **Better Code: Relationships** — Managing UI object relationships

---

_"A good user interface is one that never lies. Every button that appears enabled should work. Every progress bar should reflect reality. Every state displayed should be true."_ — Sean Parent
