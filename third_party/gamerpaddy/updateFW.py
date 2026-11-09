import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import serial.tools.list_ports
import struct
import binascii
import os
import threading
from serial import Serial, SerialException
import time
from typing import List, Tuple, Optional

class FYbiFirmwareUpdaterGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("FY Firmware Update Utility by gamerpaddy")
        self.root.geometry("800x700")
        self.root.resizable(True, True)
        
        self.firmware_data = bytearray()
        self.serial_port = None
        self.baud_rate = 115200
        self.is_uploading = False
        self.serial_conn = None
        
        self.setup_gui()
        self.refresh_com_ports()
        
    def setup_gui(self):
        # Main frame
        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # COM port selection
        ttk.Label(main_frame, text="COM Port:").grid(row=0, column=0, sticky=tk.W, pady=5)
        self.com_port_var = tk.StringVar()
        self.com_port_combo = ttk.Combobox(main_frame, textvariable=self.com_port_var, width=15)
        self.com_port_combo.grid(row=0, column=1, sticky=tk.W, pady=5)
        
        ttk.Button(main_frame, text="Refresh", command=self.refresh_com_ports).grid(row=0, column=2, padx=5, pady=5)
        
        # Baud rate selection
        ttk.Label(main_frame, text="Baud Rate:").grid(row=1, column=0, sticky=tk.W, pady=5)
        self.baud_rate_var = tk.StringVar(value="115200")
        baud_combo = ttk.Combobox(main_frame, textvariable=self.baud_rate_var, width=15)
        baud_combo['values'] = ('9600', '19200', '38400', '57600', '115200')
        baud_combo.grid(row=1, column=1, sticky=tk.W, pady=5)
        
        # File selection
        ttk.Label(main_frame, text="Firmware File:").grid(row=2, column=0, sticky=tk.W, pady=5)
        self.file_path_var = tk.StringVar()
        ttk.Entry(main_frame, textvariable=self.file_path_var, width=40).grid(row=2, column=1, sticky=tk.W, pady=5)
        ttk.Button(main_frame, text="Browse", command=self.browse_file).grid(row=2, column=2, padx=5, pady=5)
        
        # File info display
        ttk.Label(main_frame, text="File Info:").grid(row=3, column=0, sticky=tk.W, pady=5)
        self.file_info_var = tk.StringVar(value="No file selected")
        ttk.Label(main_frame, textvariable=self.file_info_var).grid(row=3, column=1, columnspan=2, sticky=tk.W, pady=5)
        
        # Connect button
        ttk.Button(main_frame, text="Check Connection", command=self.check_connection).grid(row=4, column=0, pady=10)
        
        # Progress bar
        ttk.Label(main_frame, text="Progress:").grid(row=5, column=0, sticky=tk.W, pady=5)
        self.progress_bar = ttk.Progressbar(main_frame, orient=tk.HORIZONTAL, length=400, mode='determinate')
        self.progress_bar.grid(row=5, column=1, columnspan=2, sticky=tk.W, pady=5)
        
        # Status label
        self.status_var = tk.StringVar(value="Ready")
        ttk.Label(main_frame, textvariable=self.status_var).grid(row=6, column=0, columnspan=3, sticky=tk.W, pady=5)
        
        # Protocol settings
        protocol_frame = ttk.LabelFrame(main_frame, text="Protocol Settings", padding="5")
        protocol_frame.grid(row=7, column=0, columnspan=3, sticky=(tk.W, tk.E), pady=5)
        
        ttk.Label(protocol_frame, text="Response Timeout (s):").grid(row=0, column=0, sticky=tk.W)
        self.timeout_var = tk.StringVar(value="3")
        ttk.Entry(protocol_frame, textvariable=self.timeout_var, width=10).grid(row=0, column=1, sticky=tk.W, padx=5)
        
        ttk.Label(protocol_frame, text="Retry Count:").grid(row=0, column=2, sticky=tk.W, padx=10)
        self.retry_var = tk.StringVar(value="3")
        ttk.Entry(protocol_frame, textvariable=self.retry_var, width=10).grid(row=0, column=3, sticky=tk.W)
        
        # Debug options
        debug_frame = ttk.LabelFrame(main_frame, text="Debug Options", padding="5")
        debug_frame.grid(row=8, column=0, columnspan=3, sticky=(tk.W, tk.E), pady=5)
        
        self.debug_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(debug_frame, text="Enable Debug Output", variable=self.debug_var).grid(row=0, column=0, sticky=tk.W)

        self.hex_debug_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(debug_frame, text="Show HEX Data", variable=self.hex_debug_var).grid(row=0, column=1, sticky=tk.W, padx=10)
        
        # Log text area with scrollbar
        log_frame = ttk.Frame(main_frame)
        log_frame.grid(row=9, column=0, columnspan=3, pady=5, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        ttk.Label(log_frame, text="Log:").grid(row=0, column=0, sticky=tk.W, pady=5)
        
        # Add clear log button
        ttk.Button(log_frame, text="Clear Log", command=self.clear_log).grid(row=0, column=1, sticky=tk.E)
        
        log_text_frame = ttk.Frame(log_frame)
        log_text_frame.grid(row=1, column=0, columnspan=2, sticky=(tk.W, tk.E, tk.N, tk.S))

        self.log_text = tk.Text(log_text_frame, height=15, width=80)
        log_scrollbar = ttk.Scrollbar(log_text_frame, orient=tk.VERTICAL, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scrollbar.set)
        
        self.log_text.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        log_scrollbar.grid(row=0, column=1, sticky=(tk.N, tk.S))
        
        # Upload button
        self.upload_button = ttk.Button(main_frame, text="Upload Firmware", command=self.start_upload)
        self.upload_button.grid(row=10, column=0, columnspan=3, pady=10)
        
        # Configure grid weights
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        main_frame.columnconfigure(1, weight=1)
        main_frame.rowconfigure(9, weight=1)
        log_text_frame.columnconfigure(0, weight=1)
        log_text_frame.rowconfigure(0, weight=1)
        
    def clear_log(self):
        """Clear the log text area"""
        self.log_text.delete(1.0, tk.END)
        
    def refresh_com_ports(self):
        """Refresh the list of available COM ports"""
        ports = serial.tools.list_ports.comports()
        port_list = [port.device for port in ports]
        self.com_port_combo['values'] = port_list
        if port_list:
            self.com_port_var.set(port_list[0])
            
    def browse_file(self):
        """Open file dialog to select FYbi file"""
        file_path = filedialog.askopenfilename(
            title="Select FYbi File",
            filetypes=[("FYbi files", "*.fybi"), ("All files", "*.*")]
        )
        if file_path:
            self.file_path_var.set(file_path)
            self.log_message(f"Selected file: {file_path}")
            
            # Display file information
            try:
                file_size = os.path.getsize(file_path)
                self.file_info_var.set(f"Size: {file_size} bytes")
                
                # Read first few bytes to show file signature
                with open(file_path, 'rb') as f:
                    header = f.read(16)
                    hex_header = binascii.hexlify(header).decode('ascii')
                    self.log_message(f"File header: {hex_header}")
            except Exception as e:
                self.log_message(f"Error reading file info: {str(e)}")
            
    def log_message(self, message):
        """Add message to log text area"""
        self.log_text.insert(tk.END, message + "\n")
        self.log_text.see(tk.END)
        self.root.update_idletasks()
        
    def debug_message(self, message):
        """Add debug message to log if debug is enabled"""
        if self.debug_var.get():
            self.log_message(f"DEBUG: {message}")
        
    def send_command(self, command, expected_responses=None, timeout=3, retries=3):
        """Send a command and wait for expected response with retries"""
        if not self.serial_conn or not self.serial_conn.is_open:
            self.log_message("Serial connection is not open")
            return False
            
        # Convert single response to list for uniform handling
        if isinstance(expected_responses, str):
            expected_responses = [expected_responses]
        elif expected_responses is None:
            expected_responses = []
            
        for attempt in range(retries):
            try:
                if command:  # Only send if command is not empty
                    self.debug_message(f"Sending command: {command}")
                    
                    # Clear input buffer
                    self.serial_conn.reset_input_buffer()
                    
                    # Send command
                    self.serial_conn.write(command.encode('ascii') + b'\n')
                
                # If no expected response, just return success
                if not expected_responses:
                    return True
                
                # Wait for response
                start_time = time.time()
                response = ""
                
                while time.time() - start_time < timeout:
                    if self.serial_conn.in_waiting > 0:
                        response += self.serial_conn.read(self.serial_conn.in_waiting).decode('ascii', errors='ignore')
                        
                        # Check for any expected response (case insensitive)
                        for expected in expected_responses:
                            if expected.lower() in response.lower():
                                self.debug_message(f"Received expected response: {response.strip()}")
                                return True
                    time.sleep(0.1)
                
                self.debug_message(f"Attempt {attempt+1}/{retries} failed. Response: {response.strip()}")
                
            except Exception as e:
                self.debug_message(f"Error sending command: {str(e)}")
                
            # Wait before retry
            if attempt < retries - 1:
                time.sleep(1)
                
        self.log_message(f"Failed to get expected response '{expected_responses}' after {retries} attempts")
        return False

    def send_command_get_response(self, command, timeout=3, retries=3):
        """Send a command and return the full response"""
        if not self.serial_conn or not self.serial_conn.is_open:
            self.log_message("Serial connection is not open")
            return None
            
        for attempt in range(retries):
            try:
                if command:  # Only send if command is not empty
                    self.debug_message(f"Sending command: {command}")
                    
                    # Clear input buffer
                    self.serial_conn.reset_input_buffer()
                    
                    # Send command
                    self.serial_conn.write(command.encode('ascii') + b'\n')
                
                # Wait for response
                start_time = time.time()
                response = ""
                
                while time.time() - start_time < timeout:
                    if self.serial_conn.in_waiting > 0:
                        response += self.serial_conn.read(self.serial_conn.in_waiting).decode('ascii', errors='ignore')
                    time.sleep(0.1)
                    
                    # Check if we have received some data and no more is coming
                    if response and time.time() - start_time > 1:
                        if self.serial_conn.in_waiting == 0:
                            break
                
                if response.strip():
                    self.debug_message(f"Received response: {response.strip()}")
                    return response.strip()
                
                self.debug_message(f"Attempt {attempt+1}/{retries} - no response received")
                
            except Exception as e:
                self.debug_message(f"Error sending command: {str(e)}")
                
            # Wait before retry
            if attempt < retries - 1:
                time.sleep(1)
                
        self.log_message(f"Failed to get response for command '{command}' after {retries} attempts")
        return None
        
    def check_connection(self):
        """Check if device is connected using the proper protocol"""
        com_port = self.com_port_var.get()
        baud_rate = int(self.baud_rate_var.get())
        timeout = int(self.timeout_var.get())
        retries = int(self.retry_var.get())
        
        if not com_port:
            messagebox.showerror("Error", "Please select a COM port")
            return
            
        try:
            self.debug_message(f"Attempting to connect to {com_port} at {baud_rate} baud")
            self.serial_conn = Serial(com_port, baud_rate, timeout=timeout)
            
            # Send UMO command to get device model
            self.log_message("Requesting device model...")
            model_response = self.send_command_get_response("UMO", timeout, retries)
            if model_response:
                self.log_message(f"Device Model: {model_response}")
            else:
                self.log_message("No response received for UMO command")
            
            # Send UVE command to get version information
            self.log_message("Requesting device version...")
            version_response = self.send_command_get_response("UVE", timeout, retries)
            if version_response:
                self.log_message(f"Device Version: {version_response}")
            else:
                self.log_message("No response received for UVE command")
              
            self.serial_conn.close()
            self.serial_conn = None
            
        except Exception as e:
            self.log_message(f"Connection error: {str(e)}")
            
    def process_firmware_data(self, file_path):
        """Load and process firmware data from file"""
        try:
            with open(file_path, 'rb') as f:
                self.firmware_data = bytearray(f.read())
                
            self.debug_message(f"Loaded {len(self.firmware_data)} bytes from file")
            
            # Strip model header if present (e.g., "FY6900__1.6>>")
            # Look for pattern: model name followed by "__" version "__" and ">>"
            original_size = len(self.firmware_data)
            header_stripped = False
            
            # Convert to string to search for header pattern
            try:
                data_str = self.firmware_data.decode('ascii', errors='ignore')
                # Look for header pattern: starts with letters/numbers, contains "__", ends with ">>"
                import re
                header_match = re.match(r'^[A-Za-z0-9]+__[^>]+>>', data_str)
                if header_match:
                    header_length = len(header_match.group().encode('ascii'))
                    self.firmware_data = self.firmware_data[header_length:]
                    header_stripped = True
                    self.log_message(f"Stripped model header: '{header_match.group()}' ({header_length} bytes)")
            except Exception as e:
                self.debug_message(f"Header detection error (continuing): {str(e)}")
            
            # Filter out control characters (based on VB code analysis)
            filtered_data = bytearray()
            #remove_chars = [0x0A, 0x0D, 0x00]  # Common control characters
            remove_chars = []
            removed_count = 0
            
            for byte in self.firmware_data:
                if byte not in remove_chars:
                    filtered_data.append(byte)
                else:
                    removed_count += 1
                    
            self.firmware_data = filtered_data
            self.debug_message(f"Removed {removed_count} control characters")
            
            # Strip the last 4 bytes from firmware data
            if len(self.firmware_data) >= 4:
                last_4_bytes = self.firmware_data[-4:]
                self.firmware_data = self.firmware_data[:-4]
                last_4_hex = binascii.hexlify(last_4_bytes).decode('ascii').upper()
                self.log_message(f"Stripped last 4 bytes: {last_4_hex}")
            else:
                self.log_message("Warning: Firmware data too short to strip last 4 bytes")
            
            if header_stripped:
                self.log_message(f"Original size: {original_size} bytes, after header removal and processing: {len(self.firmware_data)} bytes")
            else:
                self.log_message(f"Processed firmware data: {len(self.firmware_data)} bytes")
            
            # Show first few bytes of processed data
            if len(self.firmware_data) > 16:
                first_bytes = binascii.hexlify(self.firmware_data[:16]).decode('ascii')
                self.debug_message(f"First 16 bytes of processed data: {first_bytes}")
                
            return True
            
        except Exception as e:
            self.log_message(f"Error processing file: {str(e)}")
            return False
            
    def calculate_checksum(self, data):
        """Calculate checksum for a data block"""
        checksum = sum(data) & 0xFFFF  # Return only 16 bits
        self.debug_message(f"Checksum calculated: {checksum} (0x{checksum:04X})")
        return checksum
        
    def upload_firmware(self):
        """Main firmware upload process following the protocol"""
        if not self.firmware_data:
            self.log_message("No firmware data to upload")
            return False
            
        com_port = self.com_port_var.get()
        baud_rate = int(self.baud_rate_var.get())
        block_size = 0x800  # 2048 bytes
        timeout = int(self.timeout_var.get())
        retries = int(self.retry_var.get())
        
        try:
            self.serial_conn = Serial(com_port, baud_rate, timeout=timeout)
            self.log_message(f"Connected to {com_port} at {baud_rate} baud")
            
            # Step 1: Send start command and expect "START" response
            if not self.send_command("<PrSTM32_START", ["START"], timeout, retries):
                self.log_message("Failed to initiate communication with device")
                self.serial_conn.close()
                return False
                
            # Split into blocks and send
            total_blocks = (len(self.firmware_data) + block_size - 1) // block_size
            self.debug_message(f"Total blocks to send: {total_blocks}")
            
            for block_num in range(total_blocks):
                if not self.is_uploading:
                    break
                    
                start = block_num * block_size
                end = min(start + block_size, len(self.firmware_data))
                block_data = self.firmware_data[start:end]
                
                # Use actual block data size, don't pad the last block
                actual_block_size = len(block_data)
                
                checksum = self.calculate_checksum(block_data)
                
                # Construct the protocol header with actual block size
                header = f"<IAPSTM32_{actual_block_size}_{block_num}_{checksum}_"
                self.debug_message(f"Sending header: {header} (actual data size: {actual_block_size} bytes)")
                
                # Step 2: Send header and expect "WrStart" response (case insensitive)
                if not self.send_command(header, ["WrStart"], timeout, retries):
                    self.log_message(f"Failed to send block {block_num} header")
                    break
                
                # Step 3: Send the actual data
                self.debug_message(f"Sending {len(block_data)} bytes of data")
                
                try:
                    # Clear input buffer before sending data
                    self.serial_conn.reset_input_buffer()
                    self.serial_conn.write(block_data)
                    
                    if self.hex_debug_var.get() and len(block_data) > 0:
                        # Show first few bytes of sent data
                        preview_bytes = min(16, len(block_data))
                        hex_preview = binascii.hexlify(block_data[:preview_bytes]).decode('ascii')
                        self.debug_message(f"First {preview_bytes} bytes of block {block_num}: {hex_preview}")
                except Exception as e:
                    self.log_message(f"Error sending data: {str(e)}")
                    break
                
                # Step 4: Wait for "WrEND" response (case insensitive)
                # Note: Device responds with "WrEND" (all caps), not "WrEnd"
                if not self.send_command("", ["WrEND"], timeout, retries):
                    self.log_message(f"Did not receive WrEND confirmation for block {block_num}")
                    break
                
                # Update progress
                progress = (block_num + 1) / total_blocks * 100
                self.progress_bar['value'] = progress
                self.status_var.set(f"Uploading: {progress:.1f}%")
                self.log_message(f"Successfully sent block {block_num+1}/{total_blocks}")
                
            # Send the final command to execute the firmware
            if self.is_uploading:
                self.log_message("Sending execution command: <PrSTM32_DO")
                if self.send_command("<PrSTM32_DO", ["RUN"], timeout, retries):
                    self.log_message("Firmware upload completed successfully")
                    self.status_var.set("Upload complete - Device is running new firmware")
                    self.is_uploading = False
                    self.upload_button.config(text="Upload Firmware", command=self.start_upload)
                else:
                    self.log_message("Firmware uploaded but device did not respond with RUN confirmation")
            else:
                self.log_message("Upload cancelled")
                
            self.serial_conn.close()
            self.serial_conn = None
            return True
            
        except Exception as e:
            self.log_message(f"Upload error: {str(e)}")
            if self.serial_conn:
                self.serial_conn.close()
                self.serial_conn = None
            return False
            
    def start_upload(self):
        """Start the upload process in a separate thread"""
        if self.is_uploading:
            return
            
        file_path = self.file_path_var.get()
        com_port = self.com_port_var.get()
        
        if not file_path:
            messagebox.showerror("Error", "Please select a firmware file")
            return
            
        if not com_port:
            messagebox.showerror("Error", "Please select a COM port")
            return
            
        # Process the firmware file
        if not self.process_firmware_data(file_path):
            return
            
        # Confirm before starting upload
        if not messagebox.askyesno("Confirm Upload", 
                                  "Are you sure you want to upload the firmware?\n\n"
                                  "Make sure the device is properly connected and powered."):
            return
            
        # Start upload in a separate thread
        self.is_uploading = True
        self.upload_button.config(text="Cancel Upload", command=self.cancel_upload)
        self.progress_bar['value'] = 0
        
        upload_thread = threading.Thread(target=self.upload_firmware)
        upload_thread.daemon = True
        upload_thread.start()
        
    def cancel_upload(self):
        """Cancel the ongoing upload"""
        self.is_uploading = False
        self.upload_button.config(text="Upload Firmware", command=self.start_upload)
        self.status_var.set("Upload cancelled")
        self.log_message("Cancelling upload...")
        
        # Close serial connection if it's open
        if self.serial_conn and self.serial_conn.is_open:
            self.serial_conn.close()
            self.serial_conn = None

if __name__ == "__main__":
    root = tk.Tk()
    app = FYbiFirmwareUpdaterGUI(root)
    root.mainloop()