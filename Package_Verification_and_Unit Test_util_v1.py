import importlib
import traceback
import pandas as pd

# Use importlib.metadata (Py3.8+) with a fallback to the importlib_metadata backport
try:
    import importlib.metadata as metadata
except ImportError:
    import importlib_metadata as metadata

# Attempt to import pytest for unit testing; if not available, define a fallback.
try:
    import pytest
except ModuleNotFoundError:
    print("pytest module not found. Using a fallback for unit testing assertions.")
    class PytestFallback:
        @staticmethod
        def fail(msg):
            raise AssertionError(msg)
    pytest = PytestFallback()

# Mapping for packages where the importable module name differs from the package name.
MODULE_NAME_MAPPING = {
    'Pillow': 'PIL',
    'scikit-learn': 'sklearn',
    'PyYAML': 'yaml',
    # Add more mappings here as needed.
}

def get_module_name(package_name):
    """
    Returns the correct module name for a given package.
    Checks MODULE_NAME_MAPPING; if not found, replaces hyphens with underscores.
    """
    if package_name in MODULE_NAME_MAPPING:
        return MODULE_NAME_MAPPING[package_name]
    return package_name.replace("-", "_")

def verify_package(package_name):
    """
    Attempts to import and test a single package.

    Returns:
        tuple: (version, log_message)
          - version: The __version__ attribute if available, "N/A" if not, or None if an error occurs.
          - log_message: A message detailing the outcome.
    """
    module_name = get_module_name(package_name)
    try:
        module = importlib.import_module(module_name)
    except Exception as e:
        err = f"❌ Failed to import module '{module_name}': {e}"
        return None, err

    if hasattr(module, '__version__'):
        version = getattr(module, '__version__')
        log = f"✅ Imported successfully. Version: {version}"
        return version, log
    elif hasattr(module, 'test') or hasattr(module, 'example'):
        try:
            if hasattr(module, 'test'):
                module.test()
            else:
                module.example()
            return "N/A", "✅ Imported successfully, and test/example executed."
        except Exception as e:
            err = f"❌ Imported but test/example failed: {e}"
            return None, err
    else:
        return "N/A", "✅ Imported successfully (no version or test function available)."

def output_results_to_csv(results, filename="package_verification.csv"):
    """
    Exports the verification results to a CSV file with three columns:
      Package Name, Version, Log Message.
    """
    df = pd.DataFrame(results, columns=["Package Name", "Version", "Log Message"])
    df.sort_values(by="Package Name", inplace=True)
    df.to_csv(filename, index=False)
    print(f"\nCSV file written to: {filename}")

def test_installed_packages():
    """
    PyTest test function that verifies the import and basic functionality
    of each installed package. It collects errors and will fail if any occur.
    """
    errors = []
    for dist in metadata.distributions():
        package_name = dist.metadata.get('Name', dist.name)
        module_name = get_module_name(package_name)
        try:
            version, log = verify_package(package_name)
            assert log, f"Empty result for package {package_name}"
            print(f"✅ {package_name} imported as '{module_name}' with result: {log}")
        except Exception as e:
            errors.append(f"{package_name} (as '{module_name}') failed: {e}")

    if errors:
        pytest.fail("Some packages failed verification:\n" + "\n".join(errors))

def main():
    """
    Main function to verify all installed packages and output the results to a CSV file.
    """
    print("🔍 Verifying installed packages...\n")
    results = []

    for dist in metadata.distributions():
        package_name = dist.metadata.get('Name', dist.name)
        version, log_message = verify_package(package_name)
        results.append((package_name, version or "", log_message))
        print(f"{package_name}: {log_message}")

    output_results_to_csv(results)

if __name__ == "__main__":
    main()
