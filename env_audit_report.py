'''
#########################################################################################################################################
Virtual Environment Discovery:
    Recursively scans a directory for virtual environments by checking for python executables in expected locations (bin/python for Unix-like systems and Scripts/python.exe for Windows).
    Package Inspection:

Uses pkg_resources to gather package names.
    Attempts to determine last access time for each package folder (not always reliable, but provides useful clues).

Environment Metadata:
    Captures Python version, installation path, and environment location.

Health Check:
    Uses pip check to find broken dependencies or unmet requirements.

Output:
    Aggregates the collected data into two CSV files:
    pip_envs_packages_info.csv: Detailed per-package info.
    pip_envs_env_info.csv: Per-environment summary with pip check results.
#########################################################################################################################################
'''

import os
import subprocess
import sys
import json
import platform
import time
import pandas as pd

def find_virtualenvs(root_dir):
    """
    Recursively search for virtual environments in the given root directory.
    A folder is considered a virtual environment if it contains a Python executable.
    
    Returns:
        A list of tuples (env_name, env_path, python_exe) where:
         - env_name is the name of the environment (folder name)
         - env_path is the full path of the environment root
         - python_exe is the full path to the python executable in that environment.
    """
    envs = []
    for dirpath, dirnames, filenames in os.walk(root_dir):
        # Check for Python executable in expected locations.
        if platform.system() == "Windows":
            candidate = os.path.join(dirpath, "Scripts", "python.exe")
        else:
            candidate = os.path.join(dirpath, "bin", "python")
        
        if os.path.isfile(candidate):
            env_name = os.path.basename(dirpath)
            envs.append((env_name, dirpath, candidate))
            # Do not search subdirectories of a found environment.
            dirnames.clear()  # Prevent descending further in this branch.
    return envs

def get_env_package_info(python_exe):
    """
    Runs a Python snippet in the given environment to retrieve:
      - Python version, installation location, environment location.
      - For each installed package (using pkg_resources.working_set):
          Package name, last accessed time and days since last accessed.
    
    Returns:
        A dictionary with keys 'env_info' and 'packages' if successful, else None.
    """
    code = r"""
import pkg_resources, os, time, json, sys
now = time.time()
env_info = {
    "Python_Version": sys.version.split()[0],
    "Python_Installation_Location": sys.executable,
    "Environment_Location": sys.prefix
}
packages = []
for dist in pkg_resources.working_set:
    package_name = dist.project_name
    # Attempt to determine the package folder by replacing '-' with '_' in the package name.
    package_folder = os.path.join(dist.location, package_name.replace('-', '_'))
    if os.path.exists(package_folder):
        stats = os.stat(package_folder)
        last_access_timestamp = stats.st_atime
        last_access_time = time.ctime(last_access_timestamp)
        days_since_last_access = round((now - last_access_timestamp)/(24*3600), 2)
    else:
        last_access_time = "Package folder not found."
        days_since_last_access = None
    packages.append({
        "Package": package_name,
        "Last_Access_Time": last_access_time,
        "Days_Since_Last_Access": days_since_last_access
    })
result = {"env_info": env_info, "packages": packages}
print(json.dumps(result))
"""
    try:
        proc = subprocess.run(
            [python_exe, "-c", code],
            capture_output=True,
            text=True,
            check=True
        )
        data = json.loads(proc.stdout)
        return data
    except Exception as e:
        print(f"Error retrieving info using {python_exe}: {e}")
        return None

def run_pip_check(python_exe):
    """
    Runs 'pip check' in the given environment.
    Returns the stdout (and stderr if any) from pip check.
    """
    try:
        proc = subprocess.run(
            [python_exe, "-m", "pip", "check"],
            capture_output=True,
            text=True,
            check=True
        )
        # If pip check finds no issues, it outputs "No broken requirements found."
        output = proc.stdout.strip()
    except subprocess.CalledProcessError as e:
        # pip check returns non-zero exit code if issues are found.
        output = e.stdout.strip() + "\n" + e.stderr.strip()
    except Exception as e:
        output = f"Error running pip check: {e}"
    return output

def main():
    # Prompt the user for the folder that contains your virtual environments.
    parent_env_dir = input("Enter the full path to the folder containing your virtual environments: ").strip()
    if not os.path.isdir(parent_env_dir):
        print(f"The directory {parent_env_dir} does not exist.")
        sys.exit(1)
    
    # Find all virtual environments under the specified parent directory.
    environments = find_virtualenvs(parent_env_dir)
    if not environments:
        print("No virtual environments found in the specified folder.")
        sys.exit(1)
    
    all_package_rows = []
    all_env_rows = []
    
    for env_name, env_path, python_exe in environments:
        print(f"Processing environment: {env_name} at {env_path}")
        
        # Get package details from the environment.
        env_data = get_env_package_info(python_exe)
        if env_data:
            env_info = env_data.get("env_info", {})
            packages = env_data.get("packages", [])
            
            for pkg in packages:
                row = {
                    "Environment Name": env_name,
                    "Python Version": env_info.get("Python_Version", ""),
                    "Python Installation Location": env_info.get("Python_Installation_Location", ""),
                    "Environment Location": env_info.get("Environment_Location", ""),
                    "Package": pkg.get("Package", ""),
                    "Last Access Time": pkg.get("Last_Access_Time", ""),
                    "Days Since Last Access": pkg.get("Days_Since_Last_Access", "")
                }
                all_package_rows.append(row)
        
        # Determine the environment's last accessed date using the env folder.
        try:
            stats = os.stat(env_path)
            env_last_access = time.ctime(stats.st_atime)
        except Exception as e:
            env_last_access = f"Error: {e}"
        
        # Run pip check in the environment.
        pip_check_output = run_pip_check(python_exe)
        
        env_row = {
            "Environment Name": env_name,
            "Environment Last Access Time": env_last_access,
            "Pip Check Output": pip_check_output
        }
        all_env_rows.append(env_row)
    
    # Create DataFrames.
    df_packages = pd.DataFrame(all_package_rows)
    df_envs = pd.DataFrame(all_env_rows)
    
    print("\nAggregated Package Info Across Virtual Environments:")
    print(df_packages)
    print("\nEnvironment-Level Info (Last Access and Pip Check):")
    print(df_envs)
    
    # Save to CSV files.
    df_packages.to_csv("pip_envs_packages_info.csv", index=False)
    df_envs.to_csv("pip_envs_env_info.csv", index=False)
    print("\nCSV files generated: 'pip_envs_packages_info.csv' and 'pip_envs_env_info.csv'.")

if __name__ == "__main__":
    main()
