  sudo ifconfig feth0 destroy 2>/dev/null                                                                                           
  sudo ifconfig feth1 destroy 2>/dev/null                                                                                           
  sudo ifconfig feth0 create                                                                                                        
  sudo ifconfig feth1 create                                                                                                        
  sudo ifconfig feth0 peer feth1                                                                                                    
  sudo ifconfig feth0 up                                                                                                            
  sudo ifconfig feth1 inet 192.168.7.1/24 up                                                                                        
  sudo chmod o+r /dev/bpf*